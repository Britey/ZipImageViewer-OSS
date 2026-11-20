import React from 'react';
import {StyleSheet, Text, View} from 'react-native';
import type {Command, ReaderPreferences, Snapshot} from './protocol';
import {RangePreference} from './RangePreference';
import {Action, Choices, Label, Meter, Section, Toggle, formatBytes, usePalette} from './controls';

export function Settings({snapshot: s, dispatch, disabled, showHelp, clearArchives, readerOnly = false}: {
  snapshot: Snapshot; dispatch: (command: Command) => Promise<boolean>; disabled: boolean; showHelp: () => void; clearArchives: () => void; readerOnly?: boolean;
}) {
  const c = usePalette();
  const update = <K extends keyof ReaderPreferences>(key: K, value: ReaderPreferences[K]) => {
    void dispatch({type: 'updatePreferences', preferences: {...s.preferences, [key]: value}});
  };
  const preview = (maximumBytes: number, maximumArchiveCount: number | null) => {
    void dispatch({type: 'previewCacheLimits', limits: {maximumBytes, maximumArchiveCount}});
  };
  const p = s.preferences;
  const byteLimits = [...new Set([500e6, 1e9, 2e9, 5e9, 10e9, s.cache.maximumBytes])].sort((a, b) => a - b);
  const archiveLimits = [...new Set([-1, 5, 10, 20, 50, s.cache.maximumArchiveCount ?? -1])].sort((a, b) => a - b);
  const left = Math.round(p.tapRatio * 100);
  const used = s.cache.maximumBytes > 0 ? s.cache.retainedBytes / s.cache.maximumBytes : 0;
  return <View style={st.root}>
    <Section title="Reader controls">
      <Toggle title="Show image rotation buttons" detail="Rotate the current image by 90°. Each turn fits the image; changing pages resets rotation." value={p.showRotationButtons} disabled={disabled} onChange={v => update('showRotationButtons', v)}/>
      <Toggle title="Show page slider" value={p.showSlider} disabled={disabled} onChange={v => update('showSlider', v)}/>
      <Toggle title="Show page count" value={p.showCount} disabled={disabled} onChange={v => update('showCount', v)}/>
      <Toggle title="Center tap toggles controls" value={p.centerTap} disabled={disabled} onChange={v => update('centerTap', v)}/>
      <Toggle title="Double-tap to zoom" detail="Turn off for rapid page taps. Pinch to zoom remains available." value={p.doubleTapZoom} disabled={disabled} onChange={v => update('doubleTapZoom', v)}/>
      <Toggle title="Animate page turns" value={p.animate} disabled={disabled} onChange={v => update('animate', v)}/>
    </Section>
    <Section title="Page turning" footer={<Label variant="caption" muted>Reversing direction swaps the actions and keeps these widths.</Label>}>
      <Choices title="Reading direction" value={p.reversed ? 'rtl' : 'ltr'} disabled={disabled}
        options={[{value: 'ltr', title: 'Left to right'}, {value: 'rtl', title: 'Right to left'}]} onChange={v => update('reversed', v === 'rtl')}/>
      <View style={st.tapZones}>
        <Choices title="Left tap area width" value={p.tapRatio} disabled={disabled}
          options={[0.1, 0.3, 0.5, 0.7, 0.9].map(value => ({value, title: `${Math.round(value * 100)}%`}))} onChange={v => update('tapRatio', v)}/>
        <View accessible accessibilityLabel={`Left tap area ${left} percent, ${p.reversed ? 'next' : 'previous'} page. Right tap area ${100 - left} percent, ${p.reversed ? 'previous' : 'next'} page.`}
          style={[st.diagram, {borderColor: c.line}]}>
          <View testID="leftTapArea" style={{...st.zone, width: `${p.tapRatio * 100}%`, backgroundColor: c.accent}}/>
          <View testID="rightTapArea" style={{...st.zone, width: `${(1 - p.tapRatio) * 100}%`, backgroundColor: c.accentSoft}}/>
        </View>
        <View style={st.legend} importantForAccessibility="no-hide-descendants" accessibilityElementsHidden>
          <Text style={[st.legendText, {color: c.text}]}><Text style={{color: c.accent}}>●</Text> {p.reversed ? 'Next' : 'Previous'} · {left}%</Text>
          <Text style={[st.legendText, {color: c.text}]}>{p.reversed ? 'Previous' : 'Next'} · {100 - left}% <Text style={{color: c.muted}}>○</Text></Text>
        </View>
      </View>
    </Section>
    <Section title="Page overview">
      <RangePreference title="Thumbnail size" value={p.thumbnailSize} disabled={disabled}
        onChange={v => update('thumbnailSize', v)}/>
    </Section>
    <Section title="Page order">
      <Choices title="Sort by" value={p.sortCriterion} disabled={disabled}
        options={[{value: 'filename', title: 'Filename'}, {value: 'modified', title: 'Modified'}, {value: 'created', title: 'Created'}]}
        onChange={v => update('sortCriterion', v)}/>
      <Choices title="Sort direction" value={p.descending ? 'descending' : 'ascending'} disabled={disabled}
        options={[{value: 'ascending', title: 'Ascending'}, {value: 'descending', title: 'Descending'}]} onChange={v => update('descending', v === 'descending')}/>
    </Section>
    {!readerOnly && <Section title="Storage" footer={<>
      <Label variant="caption" muted>Limits are reviewed before they apply. Original archive files stay where they are, and extraction may briefly use extra space.</Label>
      <Label variant="caption" muted>Encrypted archives are cached decrypted and reopen without a password. Passwords are never saved.</Label>
    </>}>
      <View style={st.usage}>
        <View style={st.usageLine}><Label variant="heading">{formatBytes(s.cache.retainedBytes)}</Label>
          <Label muted variant="caption">of {formatBytes(s.cache.maximumBytes)} · {s.cache.archiveCount} {s.cache.archiveCount === 1 ? 'archive' : 'archives'}</Label></View>
        <Meter fraction={used} tone={used > 0.9 ? 'danger' : 'accent'}/>
        {s.cache.pendingDeletionBytes > 0 && <Label variant="caption" muted>{formatBytes(s.cache.pendingDeletionBytes)} awaiting cleanup</Label>}
      </View>
      <Toggle title="Compress extracted images" detail="Uses JPEG XL for new imports. JPEG is repacked losslessly; PNG may lose slight quality. Existing images stay unchanged." value={s.compressImages}
        disabled={disabled} onChange={enabled => {void dispatch({type: 'setCompression', enabled});}}/>
      <Choices title="Retained storage limit" value={s.cache.maximumBytes} disabled={disabled}
        options={byteLimits.map(value => ({value, title: formatBytes(value)}))}
        onChange={v => preview(v, s.cache.maximumArchiveCount)}/>
      <Choices title="Retained archive limit" value={s.cache.maximumArchiveCount ?? -1} disabled={disabled}
        options={archiveLimits.map(value => ({value, title: value === -1 ? 'Unlimited' : String(value)}))}
        onChange={v => preview(s.cache.maximumBytes, v === -1 ? null : v)}/>
      <View style={st.buttonRow}><Action title="Clear cached library…" testID="clearArchives" kind="danger" disabled={disabled || s.archives.length === 0} onPress={clearArchives}/></View>
    </Section>}
    {!readerOnly && s.capabilities.pickerPreferences && <Section title="Opening archives"
      footer={<Label variant="caption" muted>Choose a file app with network support, or add a network provider to System files. You can also share an archive or use Open with from another app.</Label>}>
      <View style={st.pickerRow}><Label style={st.grow}>File picker</Label>
        <Label muted style={st.pickerValue} numberOfLines={2}>{s.picker?.mode === 'selected' ? s.picker.label || `Selected picker${s.picker.packageName ? `: ${s.picker.packageName}` : ''}` : s.picker?.mode === 'ask' ? 'Ask each time' : 'System files'}</Label></View>
      <View style={st.buttonRow}><Action title="Configure file picker" disabled={disabled} onPress={() => {void dispatch({type: 'configurePicker'});}}/></View>
      {s.picker && <Toggle title="Show all files" detail="Archive format is checked after selection." value={s.picker.showAllFiles} disabled={disabled}
        onChange={enabled => {void dispatch({type: 'setShowAllFiles', enabled});}}/>}
    </Section>}
    <Section title="Help" footer={<Label variant="caption" muted style={st.about}>ZipImageViewer · Offline archive reader</Label>}>
      <View style={st.buttonRow}><Action title="Reader gestures" onPress={showHelp}/></View>
    </Section>
  </View>;
}
const st = StyleSheet.create({
  root: {gap: 26}, grow: {flex: 1},
  tapZones: {paddingBottom: 14},
  diagram: {flexDirection: 'row', direction: 'ltr', height: 56, borderRadius: 12, overflow: 'hidden', borderWidth: StyleSheet.hairlineWidth, marginTop: 4},
  zone: {height: '100%'},
  legend: {flexDirection: 'row', flexWrap: 'wrap', direction: 'ltr', justifyContent: 'space-between', gap: 8, marginTop: 8},
  legendText: {maxWidth: '100%', fontSize: 13, fontWeight: '600'},
  usage: {gap: 8, paddingVertical: 14},
  usageLine: {flexDirection: 'row', alignItems: 'baseline', gap: 8, flexWrap: 'wrap'},
  buttonRow: {paddingVertical: 12},
  pickerRow: {flexDirection: 'row', alignItems: 'center', gap: 12, minHeight: 52, paddingVertical: 8},
  pickerValue: {flexShrink: 1, textAlign: 'right'},
  about: {textAlign: 'center', marginTop: 8},
});
