import React from 'react';
import {StyleSheet, Text, View} from 'react-native';
import NativeArchiveCover from '../specs/NativeArchiveCover';
import type {Archive} from './protocol';
import {Action, Badge, Card, Label, formatBytes, styles as controls, usePalette} from './controls';

export const readingPosition = (a: Archive) => a.pageCount === 0 ? 'No pages' :
  `Page ${a.currentPage ?? Math.min(a.pageCount, Math.max(1, Math.round(a.progress * a.pageCount)))} of ${a.pageCount}`;
export function openedDate(value?: string) {
  if (!value) {return 'Not opened yet';}
  const date = new Date(value);
  return Number.isNaN(date.getTime()) ? 'Unknown' : date.toLocaleString(undefined, {year: 'numeric', month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit'});
}

export function ArchiveCard({archive, disabled, open, details}: {
  archive: Archive; disabled: boolean; open: () => void; details: () => void;
}) {
  const c = usePalette();
  const percent = Math.round(archive.progress * 100);
  return <Card style={s.card}><View style={s.summary}>
    <View style={[s.coverFrame, {backgroundColor: c.surfaceAlt, borderColor: c.line}]}>
      <NativeArchiveCover archiveId={archive.available ? archive.id : ''} testID={`cover_${archive.id}`} accessible={false} style={s.cover}/>
    </View>
    <View style={[controls.grow, s.info]}>
      <View style={s.badges}>
        {archive.format && <Badge title={archive.format.toUpperCase()}/>}
        {!archive.available && <Badge title="UNAVAILABLE" tone="danger"/>}
      </View>
      <Label variant="heading" numberOfLines={2} style={s.title}>{archive.title}</Label>
      <Label variant="caption" muted>{archive.pageCount} pages · {formatBytes(archive.retainedBytes)}</Label>
      <View style={s.position}>
        <Label variant="caption" style={s.positionText}>{archive.available ? readingPosition(archive) : 'Cached images unavailable'}</Label>
        <Text style={[s.percent, {color: archive.progress > 0 ? c.accent : c.muted}]}>{percent}% read</Text>
      </View>
      <View accessibilityRole="progressbar" accessibilityLabel={`Reading progress for ${archive.title}`}
        accessibilityValue={{min: 0, max: 100, now: percent}} style={[s.progress, {backgroundColor: c.track}]}>
        <View style={[s.progressFill, {width: `${archive.progress * 100}%`, backgroundColor: c.accent}]}/>
      </View>
    </View></View>
    <View style={s.actions}><View style={controls.grow}><Action title={archive.available ? archive.progress > 0 ? 'Resume reading' : 'Read archive' : 'Select archive again'}
      kind="primary" disabled={disabled} onPress={open}/></View><Action title="Details" onPress={details} testID={`details_${archive.id}`}/></View>
  </Card>;
}
const s = StyleSheet.create({
  card: {flexGrow: 1, gap: 14},
  summary: {flexDirection: 'row', gap: 14},
  coverFrame: {width: 76, height: 108, borderRadius: 10, overflow: 'hidden', borderWidth: StyleSheet.hairlineWidth},
  cover: {width: '100%', height: '100%'},
  info: {gap: 4, justifyContent: 'center'},
  badges: {flexDirection: 'row', flexWrap: 'wrap', gap: 6},
  title: {fontSize: 17, lineHeight: 22},
  position: {flexDirection: 'row', flexWrap: 'wrap', alignItems: 'baseline', gap: 8, marginTop: 6},
  positionText: {flexGrow: 1, flexShrink: 1, maxWidth: '100%'},
  percent: {fontSize: 13, lineHeight: 18, fontWeight: '700', fontVariant: ['tabular-nums']},
  progress: {height: 5, borderRadius: 3, overflow: 'hidden'},
  progressFill: {height: 5, borderRadius: 3},
  actions: {flexDirection: 'row', gap: 10, marginTop: 'auto'},
});
