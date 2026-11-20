import React, {useEffect, useMemo, useRef, useState} from 'react';
import {PanResponder, StyleSheet, View} from 'react-native';

/** Sends bounded previews while dragging, then always sends the exact release page. */
export function PagePosition({page, count, disabled, select}: {
  page: number; count: number; disabled: boolean; select: (page: number, scrubbing: boolean) => void;
}) {
  const [draft, setDraft] = useState(page);
  const width = useRef(0);
  const start = useRef(0);
  const target = useRef(page);
  const dragging = useRef(false);
  const timer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const latest = useRef({count, disabled, select}); latest.current = {count, disabled, select};
  const clear = () => {if (timer.current) {clearTimeout(timer.current); timer.current = null;}};
  useEffect(() => {if (!dragging.current) {target.current = page; setDraft(page);}}, [page]);
  useEffect(() => {
    if (disabled) {clear(); dragging.current = false; target.current = page; setDraft(page);}
    return clear;
  }, [disabled, count]);
  const preview = (x: number) => {
    if (!width.current) {return;}
    const next = Math.min(latest.current.count, Math.max(1, Math.round(1 + (latest.current.count - 1) * x / width.current)));
    target.current = next; setDraft(next);
    if (!timer.current) {timer.current = setTimeout(() => {timer.current = null; if (dragging.current) {latest.current.select(target.current, true);}}, 50);}
  };
  const release = () => {
    clear();
    if (dragging.current && !latest.current.disabled) {latest.current.select(target.current, false);}
    dragging.current = false;
  };
  const responder = useMemo(() => PanResponder.create({
    onStartShouldSetPanResponder: () => !latest.current.disabled && latest.current.count > 1,
    onPanResponderGrant: event => {start.current = event.nativeEvent.locationX; dragging.current = true; preview(start.current);},
    onPanResponderMove: (_, gesture) => {if (dragging.current) {preview(start.current + gesture.dx);}},
    onPanResponderRelease: release, onPanResponderTerminate: release,
    onPanResponderTerminationRequest: () => true,
  }), []);
  const progress = count <= 1 ? 0 : (draft - 1) / (count - 1);
  return <View testID="readerPageSlider" accessible accessibilityLabel="Page position"
    accessibilityState={{disabled: disabled || count < 2}} accessibilityValue={{min: 1, max: Math.max(1, count), now: draft, text: `Page ${draft} of ${count}`}}
    onLayout={event => {width.current = event.nativeEvent.layout.width;}} {...responder.panHandlers} style={s.hit}>
    <View pointerEvents="none" style={s.track}><View style={{height: 4, width: `${progress * 100}%`, backgroundColor: 'white', borderRadius: 2}}/></View>
    <View pointerEvents="none" style={[s.thumb, {left: `${progress * 100}%`}]} />
  </View>;
}
const s = StyleSheet.create({hit: {flex: 1, height: 48, justifyContent: 'center', marginHorizontal: 12},
  track: {height: 4, backgroundColor: 'rgba(255,255,255,0.22)', borderRadius: 2, overflow: 'hidden'},
  thumb: {position: 'absolute', top: 15, width: 18, height: 18, borderRadius: 9, backgroundColor: 'white', marginLeft: -9,
    shadowColor: '#000', shadowOpacity: 0.35, shadowRadius: 4, shadowOffset: {width: 0, height: 1}, elevation: 3}});
