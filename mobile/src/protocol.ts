/** Versioned wire protocol. Native services own durable state and operation lifetimes. */
export type ReaderPreferences = {
  showRotationButtons: boolean; showSlider: boolean; showCount: boolean; centerTap: boolean; reversed: boolean;
  doubleTapZoom: boolean; animate: boolean; tapRatio: number; sortCriterion: 'filename' | 'modified' | 'created';
  descending: boolean; thumbnailSize: number;
};
export type Archive = {
  id: string; title: string; pageCount: number; retainedBytes: number;
  available: boolean; progress: number; lastOpenedAt?: string;
  currentPage?: number; format?: string;
};
export type ImportState = {
  id: string; phase: string; fraction: number | null; busy: boolean;
  passwordRequired: boolean; passwordMessage?: string; cancellable: boolean;
};
export type CacheLimits = {maximumBytes: number; maximumArchiveCount: number | null};
export type CachePreview = {
  token: string; limits: CacheLimits; victims: Array<{id: string; title: string}>;
  changed: boolean; reclaimedBytes?: number;
};
export type ReaderUI = {
  page: number; count: number; displayedPage: number | null; controls: boolean; sorting: boolean;
  failed: boolean; detailFailed: boolean; tool: 'jump' | 'pages' | 'settings' | 'help' | null;
  sequence?: number; temporary: boolean; noticePending: boolean; notice?: string;
};
export type Reader = {id: string; title: string; archiveId?: string; ui?: ReaderUI};
export type ReaderAction = 'seek' | 'toggleControls' | 'showControls' | 'openJump' | 'openPages' | 'openSettings' | 'openHelp' |
  'rotateCounterclockwise' | 'rotateClockwise' | 'dismissTool' | 'retry' | 'retryDetail' | 'acknowledgeNotice' | 'back' | 'close';
export type Snapshot = {
  protocolVersion: 1; revision: number; ready: boolean; busy?: boolean;
  capabilities: {pickerPreferences: boolean};
  archives: Archive[]; preferences: ReaderPreferences; compressImages: boolean;
  cache: CacheLimits & {retainedBytes: number; archiveCount: number; pendingDeletionBytes: number};
  import: ImportState | null;
  reader: Reader | null;
  error: {id: string; title: string; message: string} | null;
  cachePreview: CachePreview | null;
  picker?: {mode: 'system' | 'ask' | 'selected'; packageName?: string; label?: string; showAllFiles: boolean};
};
export type Command =
  | {type: 'refresh'}
  | {type: 'pickArchive'}
  | {type: 'openArchive'; id: string}
  | {type: 'pickArchiveOnce'}
  | {type: 'submitPassword'; operationId: string; password: string}
  | {type: 'cancelImport'; operationId: string}
  | {type: 'closeReader'}
  | {type: 'readerAction'; readerId: string; action: ReaderAction; page?: number; scrubbing?: boolean; sequence?: number}
  | {type: 'presentationReady'}
  | {type: 'updatePreferences'; preferences: ReaderPreferences}
  | {type: 'setCompression'; enabled: boolean}
  | {type: 'removeArchive'; id: string}
  | {type: 'clearArchives'}
  | {type: 'previewCacheLimits'; limits: CacheLimits}
  | {type: 'applyCachePreview'; token: string}
  | {type: 'dismissCachePreview'}
  | {type: 'dismissError'; id: string}
  | {type: 'configurePicker'}
  | {type: 'setShowAllFiles'; enabled: boolean};
