import React, {useEffect, useMemo, useRef, useState} from 'react';
import {PanResponder, StyleSheet, View} from 'react-native';
import {Action, Label, styles, usePalette} from './controls';

/** Continuous sizing with smaller/larger buttons. */
export function RangePreference({title, value, disabled, onChange}: {
  title: string; value: number; disabled: boolean; onChange: (value: number) => void;
}) {
  const [draft, setDraft] = useState(value);
  const current = useRef(value);
  const width = useRef(0);
  const start = useRef(0);
  const dragging = useRef(false);
  const latest = useRef({value, disabled, onChange});
  latest.current = {value, disabled, onChange};
  const c = usePalette();
  const preview = (next: number) => {
    current.current = Math.min(1, Math.max(0, next));
    setDraft(current.current);
  };
  useEffect(() => {
    if (disabled || !dragging.current) {dragging.current = false; current.current = value; setDraft(value);}
  }, [value, disabled]);
  const adjust = (delta: number) => {
    if (!latest.current.disabled) {latest.current.onChange(Math.min(1, Math.max(0, current.current + delta)));}
  };
  const responder = useMemo(() => PanResponder.create({
    onStartShouldSetPanResponder: () => !latest.current.disabled,
    onMoveShouldSetPanResponder: (_, gesture) => !latest.current.disabled && Math.abs(gesture.dx) > Math.abs(gesture.dy),
    onPanResponderGrant: event => {
      start.current = event.nativeEvent.locationX;
      dragging.current = true;
      if (width.current > 0) {preview(start.current / width.current);}
    },
    onPanResponderMove: (_, gesture) => {
      if (dragging.current && width.current > 0) {preview((start.current + gesture.dx) / width.current);}
    },
    onPanResponderRelease: () => {
      if (dragging.current && !latest.current.disabled) {latest.current.onChange(current.current);}
      dragging.current = false;
    },
    onPanResponderTerminationRequest: () => true,
    onPanResponderTerminate: () => {dragging.current = false; preview(latest.current.value);},
  }), []);
  return <View style={styles.section}>
    <View style={s.header}><Label style={s.title}>{title}</Label><Label muted style={s.value}>{Math.round(draft * 100)}%</Label></View>
    <View style={s.controls}>
      <Action title="Smaller thumbnails" icon="−" disabled={disabled || draft <= 0} onPress={() => adjust(-0.05)}/>
      <View testID="thumbnailSizeRange" accessible accessibilityLabel={title}
        accessibilityState={{disabled}} accessibilityValue={{min: 0, max: 100, now: Math.round(draft * 100)}}
        onLayout={event => {width.current = event.nativeEvent.layout.width;}}
        {...responder.panHandlers} style={[s.trackHit, {opacity: disabled ? 0.45 : 1}]}>
        <View pointerEvents="none" style={[s.track, {backgroundColor: c.track}]}>
          <View style={{width: `${draft * 100}%`, height: 6, backgroundColor: c.accent}}/>
        </View>
        <View pointerEvents="none" style={[s.thumb, {left: `${draft * 100}%`, borderColor: c.accent, backgroundColor: c.surface}]}/>
      </View>
      <Action title="Larger thumbnails" icon="+" disabled={disabled || draft >= 1} onPress={() => adjust(0.05)}/>
    </View>
    <Label variant="caption" muted>Smaller thumbnails show more pages in the overview.</Label>
  </View>;
}
const s = StyleSheet.create({header: {flexDirection: 'row', justifyContent: 'space-between', alignItems: 'baseline', gap: 8},
  title: {flexShrink: 1}, value: {flexShrink: 0, fontVariant: ['tabular-nums']}, controls: {flexDirection: 'row', alignItems: 'center', gap: 4},
  trackHit: {flex: 1, height: 48, justifyContent: 'center', marginHorizontal: 12},
  track: {height: 6, borderRadius: 3, overflow: 'hidden'},
  thumb: {position: 'absolute', width: 24, height: 24, borderRadius: 12, borderWidth: 3, marginLeft: -12, top: 12,
    shadowColor: '#000', shadowOpacity: 0.18, shadowRadius: 3, shadowOffset: {width: 0, height: 1}, elevation: 2}});
