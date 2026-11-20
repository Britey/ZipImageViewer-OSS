import React from 'react';
import {FlatList, Modal, Platform, Pressable, StyleSheet, Text, TextInput} from 'react-native';
import renderer, {act} from 'react-test-renderer';
import {ReaderApp} from '../ReaderApp';
import {PagePosition} from '../PagePosition';
import {Action, Choices, Toggle} from '../controls';
import {useNativeLibrary} from '../useNativeLibrary';
import type {Command, Snapshot} from '../protocol';

jest.mock('../useNativeLibrary');
jest.mock('react-native-safe-area-context', () => ({SafeAreaView: require('react-native').View, SafeAreaProvider: require('react-native').View}));
const mockLibrary = jest.mocked(useNativeLibrary);
const dispatch = jest.fn(async (_command: Command) => true);
let tree: renderer.ReactTestRenderer;
function state(): Snapshot {
  return {protocolVersion: 1, revision: 1, ready: true, busy: false, capabilities: {pickerPreferences: false}, archives: [],
    preferences: {showRotationButtons: false, showSlider: true, showCount: true, centerTap: true, doubleTapZoom: true, reversed: false, animate: false, tapRatio: 0.3,
      sortCriterion: 'filename', descending: false, thumbnailSize: 0.25}, compressImages: false,
    cache: {maximumBytes: 2e9, maximumArchiveCount: null, retainedBytes: 0, archiveCount: 0, pendingDeletionBytes: 0},
    import: null, error: null, cachePreview: null,
    reader: {id: 'session-42', archiveId: 'archive-1', title: 'Book', ui: {page: 2, count: 10, displayedPage: 2, controls: true,
      sorting: false, failed: false, detailFailed: false, tool: null, temporary: false, noticePending: false, sequence: 50}}};
}
function setState(s: Snapshot) {mockLibrary.mockReturnValue({snapshot: s, error: null, pending: false, dispatch, retry: jest.fn(), dismissError: jest.fn()});}
async function mount(s = state()) {setState(s); await act(async () => {tree = renderer.create(<ReaderApp/>);});}
async function press(id: string) {
  await act(async () => tree.root.findAll(n => n.props.testID === id && n.props.onPress).at(-1)!.props.onPress());
}
beforeEach(() => dispatch.mockClear());
afterEach(async () => {if (tree) {await act(async () => tree.unmount());} jest.restoreAllMocks();});

it('dispatches tools and close against the native session, preserving its page identity', async () => {
  await mount(); await press('readerPages');
  expect(dispatch).toHaveBeenLastCalledWith({type: 'readerAction', readerId: 'session-42', action: 'openPages'});
  await press('readerClose');
  expect(dispatch).toHaveBeenLastCalledWith({type: 'readerAction', readerId: 'session-42', action: 'close'});
});
it('uses sequences above the native snapshot after a React reconnect and selects the exact release', async () => {
  await mount(); const slider = tree.root.findByType(PagePosition);
  await act(async () => {slider.props.select(8, true); slider.props.select(9, false);});
  expect(dispatch.mock.calls.map(([c]) => c)).toEqual([
    {type: 'readerAction', readerId: 'session-42', action: 'seek', page: 8, scrubbing: true, sequence: 51},
    {type: 'readerAction', readerId: 'session-42', action: 'seek', page: 9, scrubbing: false, sequence: 52},
  ]);
});
it('keeps page jump available when the count and slider are both hidden', async () => {
  const s = state(); s.preferences.showCount = false; s.preferences.showSlider = false;
  await mount(s);
  expect(tree.root.findAllByType(PagePosition)).toHaveLength(0);
  expect(tree.root.findAll(n => n.props.testID === 'readerPageButton' && n.props.accessibilityValue).at(-1)!.props.accessibilityValue.text).toBe('Current page 2 of 10');
  await press('readerPageButton'); expect(dispatch).toHaveBeenCalledWith({type: 'readerAction', readerId: 'session-42', action: 'openJump'});
});
it('removes chrome touch surfaces when hidden, keeping the native canvas available', async () => {
  const s = state(); s.reader!.ui!.controls = false; await mount(s);
  expect(tree.root.findAllByProps({testID: 'readerClose'}).length > 0).toBe(false);
});
it.each(['0', '11', '-1', '1.5', 'abc', '99999999999999999999'])('rejects invalid page jump %s', async input => {
  const s = state(); s.reader!.ui!.tool = 'jump'; await mount(s);
  await act(async () => tree.root.findByType(TextInput).props.onChangeText(input));
  expect(tree.root.findAllByType(Action).find(n => n.props.testID === 'confirmPageJump')!.props.disabled).toBe(true);
  expect(dispatch).not.toHaveBeenCalled();
});
it('jumps to the last page and explicitly dismisses the tool', async () => {
  const s = state(); s.reader!.ui!.tool = 'jump'; await mount(s);
  await act(async () => tree.root.findByType(TextInput).props.onChangeText(' 10 '));
  await act(async () => tree.root.findAllByType(Action).find(n => n.props.testID === 'confirmPageJump')!.props.onPress());
  expect(dispatch).toHaveBeenNthCalledWith(1, {type: 'readerAction', readerId: 'session-42', action: 'seek', page: 10, sequence: 51, scrubbing: false});
  expect(dispatch).toHaveBeenNthCalledWith(2, {type: 'readerAction', readerId: 'session-42', action: 'dismissTool'});
});
it('renders shared reader settings without exposing destructive storage actions', async () => {
  const s = state(); s.reader!.ui!.tool = 'settings'; await mount(s);
  expect(tree.root.findAllByType(Toggle).map(n => n.props.title)).toContain('Show page slider');
  expect(tree.root.findAllByType(Choices).some(n => n.props.title.includes('Retained'))).toBe(false);
  await act(async () => tree.root.findAllByType(Toggle).find(n => n.props.title === 'Animate page turns')!.props.onChange(true));
  expect(dispatch).toHaveBeenCalledWith({type: 'updatePreferences', preferences: {...s.preferences, animate: true}});
});
it('routes temporary-copy acknowledgement to the native session', async () => {
  const s = state(); s.reader!.ui!.temporary = true; s.reader!.ui!.noticePending = true; await mount(s);
  expect(tree.root.findByType(Modal).props.visible).toBe(true);
  await act(async () => tree.root.findAllByType(Action).find(n => n.props.testID === 'readerNoticeDone')!.props.onPress());
  expect(dispatch).toHaveBeenCalledWith({type: 'readerAction', readerId: 'session-42', action: 'acknowledgeNotice'});
});
it('presents a replacement import over the existing native reader with the current operation ID', async () => {
  const s = state(); s.import = {id: 'import-new', phase: 'waitingForPassword', fraction: null, busy: true,
    passwordRequired: true, cancellable: true};
  s.reader!.ui!.tool = 'pages'; await mount(s);
  expect(tree.root.findAll(n => n.props.testID === 'thumbnailGrid')).toHaveLength(0);
  await act(async () => tree.root.findByType(TextInput).props.onChangeText(' exact password '));
  await press('submitPassword');
  expect(dispatch).toHaveBeenLastCalledWith({type: 'submitPassword', operationId: 'import-new', password: ' exact password '});
});


it('changes double-tap zoom during reading and reflects the persisted native value after reconnect', async () => {
  const s = state(); s.reader!.ui!.tool = 'settings'; await mount(s);
  const toggle = () => tree.root.findAllByType(Toggle).find(n => n.props.title === 'Double-tap to zoom')!;
  expect(toggle().props.value).toBe(true);
  await act(async () => toggle().props.onChange(false));
  expect(dispatch).toHaveBeenLastCalledWith({type: 'updatePreferences', preferences: {...s.preferences, doubleTapZoom: false}});
  setState({...s, revision: 2, preferences: {...s.preferences, doubleTapZoom: false}});
  await act(async () => tree.update(<ReaderApp/>));
  expect(toggle().props.value).toBe(false);
});


it('shows rotation controls live before settings and dispatches both directions to the native session', async () => {
  const s = state(); await mount(s);
  expect(tree.root.findAllByProps({testID: 'readerRotateClockwise'})).toHaveLength(0);
  s.preferences.showRotationButtons = true; setState({...s, revision: 2});
  await act(async () => tree.update(<ReaderApp/>));
  const ids = tree.root.findAll(n => n.props.onPress && n.props.testID).map(n => n.props.testID);
  expect(ids.indexOf('readerRotateClockwise')).toBeLessThan(ids.indexOf('readerSettings'));
  await press('readerRotateCounterclockwise'); await press('readerRotateClockwise');
  expect(dispatch.mock.calls.map(([c]) => c)).toEqual([
    {type: 'readerAction', readerId: 'session-42', action: 'rotateCounterclockwise'},
    {type: 'readerAction', readerId: 'session-42', action: 'rotateClockwise'},
  ]);
  s.reader!.ui!.tool = 'settings'; setState({...s, revision: 3});
  await act(async () => tree.update(<ReaderApp/>));
  await act(async () => tree.root.findAllByType(Toggle).find(n => n.props.title === 'Show image rotation buttons')!.props.onChange(false));
  expect(dispatch).toHaveBeenLastCalledWith({type: 'updatePreferences', preferences: {...s.preferences, showRotationButtons: false}});
});


it('uses the measured overview width and scrolls to the row containing a late page', async () => {
  const s = state(); s.reader!.ui!.tool = 'pages'; s.reader!.ui!.count = 200; s.reader!.ui!.page = 137;
  await mount(s);
  const grid = () => tree.root.findByType(FlatList);
  await act(async () => grid().props.onLayout({nativeEvent: {layout: {width: 984}}}));
  expect(grid().props.numColumns).toBe(5);
  expect(grid().props.initialScrollIndex).toBe(27);
  const layout = grid().props.getItemLayout(null, 27);
  expect(layout.offset).toBe(8 + 27 * layout.length);
  const cell = grid().props.renderItem({item: 136, index: 136});
  const cellStyle = StyleSheet.flatten(cell.props.style({pressed: false}));
  expect(cellStyle.width).toBe(193);
  expect(cellStyle.height).toBe(layout.length);
  expect(cell.props.accessibilityState.selected).toBe(true);
  await act(async () => cell.props.onPress());
  expect(dispatch).toHaveBeenNthCalledWith(1, {type: 'readerAction', readerId: 'session-42', action: 'seek', page: 137, sequence: 51, scrubbing: false});
  expect(dispatch).toHaveBeenNthCalledWith(2, {type: 'readerAction', readerId: 'session-42', action: 'dismissTool'});
  await act(async () => grid().props.onLayout({nativeEvent: {layout: {width: 304}}}));
  expect(grid().props.numColumns).toBe(2);
  expect(grid().props.initialScrollIndex).toBe(68);
});

it('leaves page label line height unscaled so native large text scaling happens once', async () => {
  const s = state(); s.reader!.ui!.tool = 'pages'; await mount(s);
  const cell = tree.root.findByType(FlatList).props.renderItem({item: 0, index: 0});
  const label = React.Children.toArray(cell.props.children).find((node: any) => node.type === Text) as React.ReactElement<any>;
  expect(StyleSheet.flatten(label.props.style).lineHeight).toBe(26);
  expect(label.props.maxFontSizeMultiplier).toBe(2);
});
