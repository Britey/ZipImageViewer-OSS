import React from 'react';
import {PanResponder, View} from 'react-native';
import renderer, {act} from 'react-test-renderer';
import {PagePosition} from '../PagePosition';

type Config = Parameters<typeof PanResponder.create>[0];
let handlers: Config;
let tree: renderer.ReactTestRenderer;
const select = jest.fn();
const event = (x: number) => ({nativeEvent: {locationX: x}} as Parameters<NonNullable<Config['onPanResponderGrant']>>[0]);
const gesture = (dx: number) => ({dx} as Parameters<NonNullable<Config['onPanResponderMove']>>[1]);
beforeEach(() => {
  jest.useFakeTimers(); select.mockClear();
  jest.spyOn(PanResponder, 'create').mockImplementation(config => {handlers = config; return {panHandlers: {}};});
});
afterEach(async () => {await act(async () => tree.unmount()); jest.useRealTimers(); jest.restoreAllMocks();});
async function mount() {
  await act(async () => {tree = renderer.create(<PagePosition page={1} count={100} disabled={false} select={select}/>);});
  tree.root.findAllByType(View).find(n => n.props.testID === 'readerPageSlider')!.props.onLayout({nativeEvent: {layout: {width: 100}}});
}
it('throttles drag previews and cancels a queued preview before exact release', async () => {
  await mount();
  await act(async () => {handlers.onPanResponderGrant!(event(0), gesture(0)); handlers.onPanResponderMove!(event(0), gesture(20)); jest.advanceTimersByTime(50);});
  expect(select).toHaveBeenLastCalledWith(21, true);
  await act(async () => {handlers.onPanResponderMove!(event(0), gesture(85)); handlers.onPanResponderRelease!(event(0), gesture(85)); jest.advanceTimersByTime(200);});
  expect(select.mock.calls).toEqual([[21, true], [85, false]]);
});
it('commits a rapid drag without waiting for the first preview timer', async () => {
  await mount();
  await act(async () => {handlers.onPanResponderGrant!(event(0), gesture(0)); handlers.onPanResponderMove!(event(0), gesture(150)); handlers.onPanResponderTerminate!(event(0), gesture(150)); jest.advanceTimersByTime(200);});
  expect(select.mock.calls).toEqual([[100, false]]);
});
it('cancels pending navigation if the canvas starts sorting', async () => {
  await mount();
  await act(async () => {handlers.onPanResponderGrant!(event(80), gesture(0)); tree.update(<PagePosition page={1} count={100} disabled select={select}/>);});
  await act(async () => {jest.advanceTimersByTime(200); handlers.onPanResponderRelease!(event(80), gesture(0));});
  expect(select).not.toHaveBeenCalled();
});
