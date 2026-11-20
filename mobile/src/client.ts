import type {Command, Snapshot} from './protocol';

export interface Transport {
  getSnapshot(): Promise<string>;
  dispatch(command: string): Promise<string>;
  onStateChanged(listener: (payload: string) => void): {remove(): void};
}

type ObjectValue = Record<string, unknown>;
const object = (value: unknown): value is ObjectValue => typeof value === 'object' && value !== null && !Array.isArray(value);
const number = (value: unknown): value is number => typeof value === 'number' && Number.isFinite(value);
const string = (value: unknown): value is string => typeof value === 'string';
const boolean = (value: unknown): value is boolean => typeof value === 'boolean';
const nullableNumber = (value: unknown) => value === null || number(value);
const limits = (value: unknown) => object(value) && number(value.maximumBytes) && value.maximumBytes >= 0 &&
  (value.maximumArchiveCount === null || (number(value.maximumArchiveCount) && Number.isInteger(value.maximumArchiveCount) && value.maximumArchiveCount >= 0));

/** Reject incompatible payloads; JavaScript never synthesizes native defaults. */
export function decodeSnapshot(payload: string): Snapshot {
  const s: unknown = JSON.parse(payload);
  if (!object(s) || s.protocolVersion !== 1 || !number(s.revision) || !Number.isSafeInteger(s.revision) || s.revision < 0 || !boolean(s.ready) || (s.busy !== undefined && !boolean(s.busy))) {
    throw new Error('The native service returned an unsupported snapshot.');
  }
  const p = s.preferences;
  const c = s.cache;
  if (!object(s.capabilities) || !boolean(s.capabilities.pickerPreferences) ||
    !object(p) || !['showRotationButtons', 'showSlider', 'showCount', 'centerTap', 'doubleTapZoom', 'reversed', 'animate', 'descending'].every(k => boolean(p[k])) ||
    !number(p.tapRatio) || p.tapRatio < 0 || p.tapRatio > 1 || !number(p.thumbnailSize) || p.thumbnailSize < 0 || p.thumbnailSize > 1 ||
    !['filename', 'modified', 'created'].includes(String(p.sortCriterion)) || !boolean(s.compressImages) ||
    !limits(c) || !object(c) || !['retainedBytes', 'archiveCount', 'pendingDeletionBytes'].every(k => number(c[k]) && Number(c[k]) >= 0) ||
    !Array.isArray(s.archives) || !s.archives.every(a => object(a) && string(a.id) && string(a.title) && number(a.pageCount) &&
      a.pageCount >= 0 && number(a.retainedBytes) && a.retainedBytes >= 0 && boolean(a.available) && number(a.progress) &&
      a.progress >= 0 && a.progress <= 1 && (a.lastOpenedAt === undefined || string(a.lastOpenedAt)) &&
      (a.currentPage === undefined || (number(a.currentPage) && Number.isInteger(a.currentPage) && a.currentPage >= 0 && a.currentPage <= a.pageCount)) &&
      (a.format === undefined || string(a.format)))) {
    throw new Error('The native service returned incomplete library or settings data.');
  }
  if (s.import !== null && (!object(s.import) || !string(s.import.id) || !string(s.import.phase) || !nullableNumber(s.import.fraction) ||
    (number(s.import.fraction) && (s.import.fraction < 0 || s.import.fraction > 1)) || !boolean(s.import.busy) ||
    !boolean(s.import.passwordRequired) || !boolean(s.import.cancellable) ||
    (s.import.passwordMessage !== undefined && !string(s.import.passwordMessage)))) {
    throw new Error('The native service returned an invalid import state.');
  }
  if (s.reader !== null && (!object(s.reader) || !string(s.reader.id) || !string(s.reader.title) || (s.reader.archiveId !== undefined && !string(s.reader.archiveId)))) {
    throw new Error('The native service returned an invalid reader state.');
  }
  if (object(s.reader) && s.reader.ui !== undefined) {
    const ui = s.reader.ui;
    if (!object(ui) || !number(ui.count) || !Number.isSafeInteger(ui.count) || ui.count < 0 ||
      !number(ui.page) || !Number.isSafeInteger(ui.page) || ui.page < 0 || ui.page > ui.count ||
      (ui.displayedPage !== null && (!number(ui.displayedPage) || !Number.isInteger(ui.displayedPage) || ui.displayedPage < 1 || ui.displayedPage > ui.count)) ||
      !['controls', 'sorting', 'failed', 'detailFailed', 'temporary', 'noticePending'].every(key => boolean(ui[key])) ||
      (ui.tool !== null && !['jump', 'pages', 'settings', 'help'].includes(String(ui.tool))) ||
      (ui.notice !== undefined && !string(ui.notice)) ||
      (ui.sequence !== undefined && (!number(ui.sequence) || !Number.isSafeInteger(ui.sequence) || ui.sequence < -1))) {
      throw new Error('The native service returned invalid reader controls.');
    }
  }
  if (s.error !== null && (!object(s.error) || !string(s.error.id) || !string(s.error.title) || !string(s.error.message))) {
    throw new Error('The native service returned an invalid error state.');
  }
  if (s.cachePreview !== null && (!object(s.cachePreview) || !string(s.cachePreview.token) || !limits(s.cachePreview.limits) ||
    !boolean(s.cachePreview.changed) || (s.cachePreview.reclaimedBytes !== undefined &&
      (!number(s.cachePreview.reclaimedBytes) || s.cachePreview.reclaimedBytes < 0)) || !Array.isArray(s.cachePreview.victims) ||
    !s.cachePreview.victims.every(v => object(v) && string(v.id) && string(v.title)))) {
    throw new Error('The native service returned an invalid storage preview.');
  }
  if (s.picker !== undefined && (!object(s.picker) || !['system', 'ask', 'selected'].includes(String(s.picker.mode)) ||
    !boolean(s.picker.showAllFiles) || (s.picker.packageName !== undefined && !string(s.picker.packageName)) ||
    (s.picker.label !== undefined && !string(s.picker.label)))) {
    throw new Error('The native service returned invalid file picker settings.');
  }
  return s as Snapshot;
}

export function acceptSnapshot(current: Snapshot | null, incoming: Snapshot): Snapshot {
  return current && incoming.revision <= current.revision ? current : incoming;
}

/** Subscription is installed before bootstrap; disposal invalidates all late promises. */
export function connectNative(
  transport: Transport,
  onSnapshot: (snapshot: Snapshot) => void,
  onError: (message: string) => void,
) {
  let active = true;
  let current: Snapshot | null = null;
  let subscription: {remove(): void} | undefined;
  const receive = (payload: string) => {
    if (!active) {return;}
    const next = acceptSnapshot(current, decodeSnapshot(payload));
    if (next !== current) {current = next; onSnapshot(next);}
  };
  const fail = (error: unknown) => {
    if (active) {onError(error instanceof Error ? error.message : 'The native service could not complete the request.');}
  };
  try {
    subscription = transport.onStateChanged(payload => {try {receive(payload);} catch (error) {fail(error);}});
    Promise.resolve(transport.getSnapshot()).then(receive).catch(fail);
  } catch (error) {fail(error);}
  return {
    async dispatch(command: Command): Promise<boolean> {
      if (!active) {return false;}
      try {receive(await transport.dispatch(JSON.stringify(command))); return active;}
      catch (error) {fail(error); return false;}
    },
    dispose() {active = false; subscription?.remove();},
  };
}
