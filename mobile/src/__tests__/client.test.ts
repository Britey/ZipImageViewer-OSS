import {acceptSnapshot, connectNative, decodeSnapshot} from '../client';
import type {Transport} from '../client';
import type {Snapshot} from '../protocol';

function snapshot(revision = 1): Snapshot {
  return {protocolVersion: 1, revision, ready: true, capabilities: {pickerPreferences: false}, archives: [],
    preferences: {showRotationButtons: false, showSlider: true, showCount: true, centerTap: true, doubleTapZoom: true, reversed: false, animate: false, tapRatio: 0.3,
      sortCriterion: 'filename', descending: false, thumbnailSize: 0.25}, compressImages: false,
    cache: {maximumBytes: 2e9, maximumArchiveCount: null, retainedBytes: 0, archiveCount: 0, pendingDeletionBytes: 0},
    import: null, reader: null, error: null, cachePreview: null};
}

function deferred<T>() {
  let resolve!: (value: T) => void;
  let reject!: (error: Error) => void;
  const promise = new Promise<T>((yes, no) => {resolve = yes; reject = no;});
  return {promise, resolve, reject};
}
const flush = async () => {await Promise.resolve(); await Promise.resolve();};

describe('native snapshot boundary', () => {
  it('accepts native preferences without inventing defaults', () => {
    const state = snapshot(); state.preferences.thumbnailSize = 0.63; state.preferences.tapRatio = 0.7;
    expect(decodeSnapshot(JSON.stringify(state))).toEqual(state);
  });
  it.each([
    {protocolVersion: 2}, {revision: -1}, {revision: 1.5}, {preferences: {}}, {capabilities: {}}, {cache: {}},
    {archives: [{id: 'bad'}]}, {import: {id: 'bad'}}, {cachePreview: {token: 'bad'}}, {error: {id: 'bad'}},
    {reader: {id: 'bad'}}, {picker: {mode: 'invented', showAllFiles: true}},
  ])('rejects incompatible state: %j', change => {
    expect(() => decodeSnapshot(JSON.stringify({...snapshot(), ...change}))).toThrow();
  });
  it('rejects invalid JSON and missing optional-null state slots', () => {
    expect(() => decodeSnapshot('{')).toThrow();
    const state: Record<string, unknown> = {...snapshot()}; delete state.import;
    expect(() => decodeSnapshot(JSON.stringify(state))).toThrow();
  });
  it.each([undefined, null, 'yes', 1])('rejects a missing or non-boolean rotation preference: %j', flag => {
    const state = snapshot();
    expect(() => decodeSnapshot(JSON.stringify({...state, preferences: {...state.preferences, showRotationButtons: flag}}))).toThrow();
  });
  it('never replaces current state with equal or older revisions', () => {
    const current = snapshot(5);
    expect(acceptSnapshot(current, snapshot(4))).toBe(current);
    expect(acceptSnapshot(current, snapshot(5))).toBe(current);
    expect(acceptSnapshot(current, snapshot(6)).revision).toBe(6);
  });
});

describe('native connection ownership', () => {
  it('subscribes before bootstrap and rejects older bootstrap / command responses', async () => {
    const initial = deferred<string>(); const command = deferred<string>();
    const order: string[] = []; let emit!: (payload: string) => void;
    const transport: Transport = {
      onStateChanged(listener) {order.push('subscribe'); emit = listener; return {remove: jest.fn()};},
      getSnapshot() {order.push('bootstrap'); return initial.promise;}, dispatch: jest.fn(() => command.promise),
    };
    const receive = jest.fn(); const error = jest.fn(); const client = connectNative(transport, receive, error);
    expect(order).toEqual(['subscribe', 'bootstrap']);
    emit(JSON.stringify(snapshot(5))); initial.resolve(JSON.stringify(snapshot(1))); await flush();
    const completion = client.dispatch({type: 'refresh'});
    emit(JSON.stringify(snapshot(7))); command.resolve(JSON.stringify(snapshot(6))); await completion;
    expect(receive.mock.calls.map(([state]: [Snapshot]) => state.revision)).toEqual([5, 7]);
    expect(error).not.toHaveBeenCalled(); client.dispose();
  });
  it('ignores every late callback after disposal, including rejected promises', async () => {
    const initial = deferred<string>(); const command = deferred<string>(); const remove = jest.fn();
    let emit!: (payload: string) => void;
    const transport: Transport = {onStateChanged(listener) {emit = listener; return {remove};}, getSnapshot: () => initial.promise, dispatch: () => command.promise};
    const receive = jest.fn(); const error = jest.fn(); const client = connectNative(transport, receive, error);
    const completion = client.dispatch({type: 'refresh'}); client.dispose();
    emit(JSON.stringify(snapshot())); initial.reject(new Error('late bootstrap')); command.reject(new Error('late command'));
    expect(await completion).toBe(false); await flush();
    expect(remove).toHaveBeenCalledTimes(1); expect(receive).not.toHaveBeenCalled(); expect(error).not.toHaveBeenCalled();
  });
  it('surfaces subscription, bootstrap, event decode and dispatch failures', async () => {
    const receive = jest.fn(); const error = jest.fn();
    const broken: Transport = {onStateChanged() {throw new Error('subscription failed');}, getSnapshot: jest.fn(), dispatch: jest.fn()};
    connectNative(broken, receive, error).dispose();
    expect(error).toHaveBeenLastCalledWith('subscription failed'); expect(broken.getSnapshot).not.toHaveBeenCalled();
    let emit!: (payload: string) => void;
    const native: Transport = {onStateChanged(listener) {emit = listener; return {remove: jest.fn()};},
      getSnapshot: () => Promise.reject(new Error('bootstrap failed')), dispatch: () => Promise.reject(new Error('dispatch failed'))};
    const client = connectNative(native, receive, error); await flush(); expect(error).toHaveBeenLastCalledWith('bootstrap failed');
    emit('{'); expect(error).toHaveBeenCalledTimes(3);
    expect(await client.dispatch({type: 'refresh'})).toBe(false); expect(error).toHaveBeenLastCalledWith('dispatch failed');
    expect(receive).not.toHaveBeenCalled(); client.dispose();
  });
  it('passes password contents and operation identity without trimming', async () => {
    const transport: Transport = {onStateChanged: () => ({remove: jest.fn()}), getSnapshot: async () => JSON.stringify(snapshot()),
      dispatch: jest.fn(async () => JSON.stringify(snapshot(2)))};
    const client = connectNative(transport, jest.fn(), jest.fn());
    const password = '  密碼\t ';
    await client.dispatch({type: 'submitPassword', operationId: 'native-operation-42', password});
    expect(JSON.parse((transport.dispatch as jest.Mock).mock.calls[0][0])).toEqual({type: 'submitPassword', operationId: 'native-operation-42', password});
    client.dispose();
  });
});


it('rejects out-of-range reader identities and malformed optional library metadata', () => {
  const s = snapshot();
  const ui = {page: 2, count: 10, displayedPage: 2, controls: true, sorting: false, failed: false, detailFailed: false,
    tool: null, temporary: false, noticePending: false};
  for (const change of [{page: 11}, {displayedPage: 11}, {count: 1.5}, {tool: 'unknown'}, {controls: 'yes'}, {sequence: 1.5}]) {
    expect(() => decodeSnapshot(JSON.stringify({...s, reader: {id: 'session', title: 'Book', ui: {...ui, ...change}}}))).toThrow();
  }
  expect(() => decodeSnapshot(JSON.stringify({...s, busy: 'yes'}))).toThrow();
});
