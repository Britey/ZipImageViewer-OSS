import React from 'react';
import {FlatList, Modal, Platform, Text, TextInput} from 'react-native';
import renderer, {act} from 'react-test-renderer';
import {LibraryApp} from '../LibraryApp';
import {Action, Label, Toggle} from '../controls';
import {useNativeLibrary} from '../useNativeLibrary';
import type {Snapshot} from '../protocol';

jest.mock('../useNativeLibrary');
jest.mock('react-native-safe-area-context', () => ({SafeAreaView: require('react-native').View}));
const mockLibrary = jest.mocked(useNativeLibrary);
const dispatch = jest.fn(async () => true);
function snapshot(): Snapshot {
  return {protocolVersion: 1, revision: 1, ready: true, capabilities: {pickerPreferences: false}, archives: [],
    preferences: {showRotationButtons: false, showSlider: true, showCount: true, centerTap: true, doubleTapZoom: true, reversed: false, animate: false, tapRatio: 0.3,
      sortCriterion: 'filename', descending: false, thumbnailSize: 0.25}, compressImages: false,
    cache: {maximumBytes: 2e9, maximumArchiveCount: null, retainedBytes: 0, archiveCount: 0, pendingDeletionBytes: 0},
    import: null, reader: null, error: null, cachePreview: null};
}
function setState(state: Snapshot, pending = false) {
  mockLibrary.mockReturnValue({snapshot: state, error: null, pending, dispatch, retry: jest.fn(), dismissError: jest.fn()});
}
let tree: renderer.ReactTestRenderer;
beforeEach(() => {dispatch.mockClear();});
afterEach(async () => {if (tree) {await act(async () => tree.unmount());} jest.restoreAllMocks();});
async function mount(state: Snapshot) {setState(state); await act(async () => {tree = renderer.create(<LibraryApp/>);});}

it('offers no fake cancel for noncancellable native import work', async () => {
  const state = snapshot(); state.import = {id: 'operation-1', phase: 'extracting', fraction: null, busy: true, passwordRequired: false, cancellable: false};
  await mount(state);
  expect(tree.root.findAllByType(Modal)).toHaveLength(1);
  expect(tree.root.findAllByType(Action).some(a => a.props.title === 'Cancel import')).toBe(false);
  expect(tree.root.findByProps({testID: 'importProgress'})).toBeTruthy();
});

it('submits exact ephemeral password against the visible native operation', async () => {
  const state = snapshot(); state.import = {id: 'operation-42', phase: 'waitingForPassword', fraction: null, busy: true, passwordRequired: true, cancellable: true};
  await mount(state);
  const input = () => tree.root.findAllByType(TextInput).find(n => n.props.testID === 'passwordInput')!;
  expect(input().props.secureTextEntry).toBe(true);
  await act(async () => input().props.onChangeText('  密碼\t '));
  await act(async () => tree.root.findAllByType(Action).find(n => n.props.testID === 'submitPassword')!.props.onPress());
  expect(dispatch).toHaveBeenCalledWith({type: 'submitPassword', operationId: 'operation-42', password: '  密碼\t '});
  expect(input().props.value).toBe('');
});

it('coordinates native errors before password prompts and acknowledges exact error ID', async () => {
  const state = snapshot(); state.error = {id: 'error-8', title: 'Unable to read archive', message: 'The native failure reason'};
  state.import = {id: 'operation-42', phase: 'waitingForPassword', fraction: null, busy: true, passwordRequired: true, cancellable: true};
  await mount(state);
  expect(tree.root.findAllByType(Modal)).toHaveLength(1);
  expect(tree.root.findAllByType(TextInput).some(n => n.props.testID === 'passwordInput')).toBe(false);
  await act(async () => tree.root.findAllByType(Action).find(n => n.props.title === 'OK')!.props.onPress());
  expect(dispatch).toHaveBeenCalledWith({type: 'dismissError', id: 'error-8'});
});

it('returns settings to the library when a native reader opens externally', async () => {
  const state = snapshot(); await mount(state);
  await act(async () => tree.root.findAllByType(Action).find(n => n.props.testID === 'openSettings')!.props.onPress());
  expect(tree.root.findByProps({testID: 'settingsScreen'})).toBeTruthy();
  setState({...state, revision: 2, reader: {id: 'reader-external', title: 'External archive'}});
  await act(async () => tree.update(<LibraryApp/>));
  expect(tree.root.findByProps({testID: 'libraryScreen'})).toBeTruthy();
  expect(tree.root.findAllByProps({testID: 'settingsScreen'})).toHaveLength(0);
});

it('keeps the physical left tap width when reading direction is reversed', async () => {
  const state = snapshot(); state.preferences.reversed = true; state.preferences.tapRatio = 0.3;
  await mount(state);
  await act(async () => tree.root.findAllByType(Action).find(n => n.props.testID === 'openSettings')!.props.onPress());
  expect(tree.root.findByProps({testID: 'leftTapArea'}).props.style.width).toBe('30%');
  expect(tree.root.findByProps({testID: 'rightTapArea'}).props.style.width).toBe('70%');
});

it('exposes settings sections to screen-reader heading navigation', async () => {
  const state = snapshot(); state.capabilities.pickerPreferences = true;
  await mount(state);
  await act(async () => tree.root.findAllByType(Action).find(n => n.props.testID === 'openSettings')!.props.onPress());
  const headings = tree.root.findAllByType(Text).filter(n => n.props.accessibilityRole === 'header').map(n => n.props.children);
  expect(headings).toEqual(expect.arrayContaining(['Reader controls', 'Page turning', 'Page overview', 'Page order', 'Storage', 'Opening archives', 'Help']));
  expect(headings).not.toContain('File picker');
});

it('notifies iOS after a shared modal finishes dismissing', async () => {
  jest.replaceProperty(Platform, 'OS', 'ios');
  await mount(snapshot());
  await act(async () => tree.root.findByType(Modal).props.onDismiss());
  expect(dispatch).toHaveBeenCalledWith({type: 'presentationReady'});
});

it('selects the stored Android Float32 tap width without changing its value', async () => {
  const state = snapshot(); state.preferences.tapRatio = Math.fround(0.3);
  await mount(state);
  await act(async () => tree.root.findAllByType(Action).find(n => n.props.testID === 'openSettings')!.props.onPress());
  const choices = tree.root.findAll(n =>
    n.props.accessibilityRole === 'radio' && n.props.accessibilityLabel?.startsWith('Left tap area width:'));
  const selected = choices.filter(n => n.props.accessibilityState.selected);
  expect(new Set(selected.map(n => n.props.accessibilityLabel))).toEqual(new Set(['Left tap area width: 30%']));
  expect(dispatch).not.toHaveBeenCalled();
});

it('can retry a native library bootstrap failure after dismissing its error', async () => {
  const state = snapshot(); state.ready = false;
  await mount(state);
  await act(async () => tree.root.findAllByType(Action).find(n => n.props.title === 'Retry loading library')!.props.onPress());
  expect(dispatch).toHaveBeenCalledWith({type: 'refresh'});
});

it('requires another user confirmation when native quota revalidation changes the victims', async () => {
  const state = snapshot();
  state.cachePreview = {token: 'preview-old', limits: {maximumBytes: 500e6, maximumArchiveCount: 5},
    victims: [{id: 'archive-a', title: 'First archive'}], changed: false};
  await mount(state);
  const apply = () => tree.root.findAllByType(Action).find(n => n.props.title === 'Apply reviewed limits')!;
  await act(async () => apply().props.onPress());
  expect(dispatch).toHaveBeenLastCalledWith({type: 'applyCachePreview', token: 'preview-old'});
  dispatch.mockClear();
  setState({...state, revision: 2, cachePreview: {...state.cachePreview, token: 'preview-new', changed: true,
    victims: [{id: 'archive-b', title: 'Different archive'}]}});
  await act(async () => tree.update(<LibraryApp/>));
  const labels = tree.root.findAllByType(Label).flatMap(n => n.props.children);
  expect(labels).toContain('Storage preview changed');
  expect(labels).toContain('Different archive');
  expect(labels).not.toContain('First archive');
  expect(dispatch).not.toHaveBeenCalled();
  await act(async () => apply().props.onPress());
  expect(dispatch).toHaveBeenCalledTimes(1);
  expect(dispatch).toHaveBeenCalledWith({type: 'applyCachePreview', token: 'preview-new'});
});


it('blocks archive opening while native storage work continues after command acceptance', async () => {
  const state = snapshot(); state.busy = true; await mount(state);
  expect(tree.root.findAllByType(Action).find(n => n.props.testID === 'openArchive')!.props.disabled).toBe(true);
});
it('offers Android one-time alternate intake only when supported', async () => {
  const state = snapshot(); state.capabilities.pickerPreferences = true; await mount(state);
  await act(async () => tree.root.findAllByType(Action).find(n => n.props.testID === 'pickArchiveOnce')!.props.onPress());
  expect(dispatch).toHaveBeenCalledWith({type: 'pickArchiveOnce'});
});

it('leaves modal ownership with the reader root while an existing session handles replacement imports', async () => {
  const state = snapshot(); state.reader = {id: 'open-session', title: 'Old archive'};
  state.import = {id: 'replacement', phase: 'waitingForPassword', fraction: null, busy: true, passwordRequired: true, cancellable: true};
  await mount(state);
  expect(tree.root.findByType(Modal).props.visible).toBe(false);
  expect(tree.root.findAllByProps({testID: 'passwordInput'})).toHaveLength(0);
});


it.each(['Café.cbz', 'Cafe\u0301.cbz'])('finds accented iOS archive title %s with an unaccented query', async title => {
  jest.replaceProperty(Platform, 'OS', 'ios');
  const state = snapshot();
  state.archives = [{id: 'accent', title, pageCount: 1, retainedBytes: 10, available: true, progress: 0}];
  await mount(state);
  await act(async () => tree.root.findByProps({testID: 'searchArchives'}).props.onChangeText(' CAFE '));
  expect(tree.root.findByType(FlatList).props.data.map((a: {id: string}) => a.id)).toEqual(['accent']);
});

it('preserves Android case-only archive search', async () => {
  jest.replaceProperty(Platform, 'OS', 'android');
  const state = snapshot();
  state.archives = [{id: 'accent', title: 'Café.cbz', pageCount: 1, retainedBytes: 10, available: true, progress: 0}];
  await mount(state);
  await act(async () => tree.root.findByProps({testID: 'searchArchives'}).props.onChangeText('cafe'));
  expect(tree.root.findByType(FlatList).props.data).toEqual([]);
});


it.each(['ios', 'android'] as const)('opens the real picker from every empty %s library', async platform => {
  jest.replaceProperty(Platform, 'OS', platform);
  const state = snapshot(); await mount(state);
  const open = () => tree.root.findAllByType(Action).find(n => n.props.testID === 'openEmptyArchive')!;
  expect(open().props.title).toBe('Open archive');
  expect(open().props.disabled).toBe(false);
  expect(tree.root.findAllByType(Action).some(n => /sample/i.test(n.props.title))).toBe(false);
  await act(async () => open().props.onPress());
  expect(dispatch).toHaveBeenLastCalledWith({type: 'pickArchive'});
  // Cancelling the native picker leaves the empty snapshot ready for another attempt.
  setState({...state, revision: 2});
  await act(async () => tree.update(<LibraryApp/>));
  await act(async () => open().props.onPress());
  expect(dispatch).toHaveBeenCalledTimes(2);
  // A real import and later cache removal bring back the same picker action.
  const archive = {id: 'imported', title: 'My book.cbz', pageCount: 3, retainedBytes: 100, available: true, progress: 0};
  setState({...state, revision: 3, archives: [archive]});
  await act(async () => tree.update(<LibraryApp/>));
  expect(tree.root.findAllByType(Action).some(n => n.props.testID === 'openEmptyArchive')).toBe(false);
  setState({...state, revision: 4});
  await act(async () => tree.update(<LibraryApp/>));
  await act(async () => open().props.onPress());
  expect(dispatch).toHaveBeenLastCalledWith({type: 'pickArchive'});
  expect(dispatch).toHaveBeenCalledTimes(3);
});

it.each(['pending', 'busy', 'import'])('disables empty-library intake during %s work', async work => {
  const state = snapshot();
  if (work === 'busy') state.busy = true;
  if (work === 'import') state.import = {id: 'import', phase: 'extracting', fraction: null, busy: true, passwordRequired: false, cancellable: true};
  setState(state, work === 'pending');
  await act(async () => {tree = renderer.create(<LibraryApp/>);});
  expect(tree.root.findAllByType(Action).find(n => n.props.testID === 'openEmptyArchive')!.props.disabled).toBe(true);
});


it('changes double-tap zoom in library settings without changing tap zones or reading direction', async () => {
  const state = snapshot(); state.preferences.reversed = true; state.preferences.tapRatio = 0.7;
  await mount(state);
  await act(async () => tree.root.findAllByType(Action).find(n => n.props.testID === 'openSettings')!.props.onPress());
  const toggle = tree.root.findAllByType(Toggle).find(n => n.props.title === 'Double-tap to zoom')!;
  expect(toggle.props.value).toBe(true);
  await act(async () => toggle.props.onChange(false));
  expect(dispatch).toHaveBeenLastCalledWith({type: 'updatePreferences', preferences: {...state.preferences, doubleTapZoom: false}});
});
