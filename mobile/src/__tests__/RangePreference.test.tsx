import React from 'react';
import {PanResponder} from 'react-native';
import renderer, {act} from 'react-test-renderer';
import {RangePreference} from '../RangePreference';
import {Action} from '../controls';

type Config = Parameters<typeof PanResponder.create>[0];
let handlers: Config;
let tree: renderer.ReactTestRenderer;
const save = jest.fn();
const event = (x: number) => ({nativeEvent: {locationX: x}} as Parameters<NonNullable<Config['onPanResponderGrant']>>[0]);
const gesture = {dx: 0} as Parameters<NonNullable<Config['onPanResponderGrant']>>[1];
const control = (value = 0.25, disabled = false) => <RangePreference title="Thumbnail size" value={value} disabled={disabled} onChange={save}/>;
beforeEach(() => {
  save.mockClear();
  jest.spyOn(PanResponder, 'create').mockImplementation(config => {handlers = config; return {panHandlers: {}};});
});
afterEach(async () => {await act(async () => tree.unmount()); jest.restoreAllMocks();});
async function drag() {
  await act(async () => {tree = renderer.create(control());});
  const track = tree.root.findAll(n => n.props.testID === 'thumbnailSizeRange' && n.props.onLayout)[0]!;
  track.props.onLayout({nativeEvent: {layout: {width: 100}}});
  await act(async () => handlers.onPanResponderGrant!(event(75), gesture));
}
const displayed = () => tree.root.findAll(n => n.props.testID === 'thumbnailSizeRange' && n.props.accessibilityValue)[0]!.props.accessibilityValue.now;

it('restores saved sizing after cancellation and bases the next adjustment on it', async () => {
  await drag(); expect(displayed()).toBe(75);
  await act(async () => handlers.onPanResponderTerminate!(event(75), gesture));
  await act(async () => tree.update(control()));
  expect(save).not.toHaveBeenCalled(); expect(displayed()).toBe(25);
  await act(async () => tree.root.findAllByType(Action).find(n => n.props.title === 'Larger thumbnails')!.props.onPress());
  expect(save).toHaveBeenCalledWith(0.3);
});
it('restores the latest native preference if it changes during a canceled drag', async () => {
  await drag();
  await act(async () => tree.update(control(0.4)));
  await act(async () => handlers.onPanResponderTerminate!(event(75), gesture));
  expect(save).not.toHaveBeenCalled(); expect(displayed()).toBe(40);
});
it('still saves the exact value once on an ordinary release', async () => {
  await drag();
  await act(async () => handlers.onPanResponderRelease!(event(75), gesture));
  expect(save.mock.calls).toEqual([[0.75]]);
});
