import React from 'react';
import {StyleSheet, Text, View, useWindowDimensions} from 'react-native';
import NativeArchiveCover from '../specs/NativeArchiveCover';
import type {Archive} from './protocol';
import {Action, Badge, Card, Label, formatBytes, usePalette} from './controls';
import {COVER_ASPECT} from './layout';

export const readingPosition = (a: Archive) => a.pageCount === 0 ? 'No pages' :
  `Page ${a.currentPage ?? Math.min(a.pageCount, Math.max(1, Math.round(a.progress * a.pageCount)))} of ${a.pageCount}`;
export function openedDate(value?: string) {
  if (!value) {return 'Not opened yet';}
  const date = new Date(value);
  return Number.isNaN(date.getTime()) ? 'Unknown' : date.toLocaleString(undefined, {year: 'numeric', month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit'});
}

export function ArchiveCard({archive, disabled, open, details, tile = false, coverWidth = 120}: {
  archive: Archive; disabled: boolean; open: () => void; details: () => void; tile?: boolean; coverWidth?: number;
}) {
  const c = usePalette();
  const {fontScale} = useWindowDimensions();
  const percent = Math.round(archive.progress * 100);
  const cover = <View style={[tile ? s.tileCover : [s.coverFrame, {width: coverWidth, height: Math.round(coverWidth / COVER_ASPECT), borderColor: c.line}],
    {backgroundColor: c.surfaceAlt}]}>
    <NativeArchiveCover archiveId={archive.available ? archive.id : ''} testID={`cover_${archive.id}`} accessible={false} style={s.cover}/>
  </View>;
  const info = <View style={[s.info, tile ? s.tileInfo : {flexBasis: Math.round(120 * Math.max(1, fontScale))}]}>
    <View style={s.badges}>
      {archive.format && <Badge title={archive.format.toUpperCase()}/>}
      {!archive.available && <Badge title="UNAVAILABLE" tone="danger"/>}
    </View>
    <Label variant="heading" numberOfLines={tile ? 2 : 3} style={s.title}>{archive.title}</Label>
    <Label variant="caption" muted>{archive.pageCount} pages · {formatBytes(archive.retainedBytes)}</Label>
    <View style={s.position}>
      <Label variant="caption" style={s.positionText}>{archive.available ? readingPosition(archive) : 'Cached images unavailable'}</Label>
      <Text style={[s.percent, {color: archive.progress > 0 ? c.accent : c.muted}]}>{percent}% read</Text>
    </View>
    <View accessibilityRole="progressbar" accessibilityLabel={`Reading progress for ${archive.title}`}
      accessibilityValue={{min: 0, max: 100, now: percent}} style={[s.progress, {backgroundColor: c.track}]}>
      <View style={[s.progressFill, {width: `${archive.progress * 100}%`, backgroundColor: c.accent}]}/>
    </View>
  </View>;
  const actions = <View style={s.actions}><View style={s.primary}><Action title={archive.available ? archive.progress > 0 ? 'Resume reading' : 'Read archive' : 'Select archive again'}
    kind="primary" disabled={disabled} onPress={open}/></View>
    <View style={s.secondary}><Action title="Details" onPress={details} testID={`details_${archive.id}`}/></View></View>;
  return tile ? <Card style={s.tileCard}>{cover}<View style={s.tileBody}>{info}{actions}</View></Card>
    : <Card style={s.card}><View style={s.summary}>{cover}{info}</View>{actions}</Card>;
}
const s = StyleSheet.create({
  card: {flexGrow: 1, gap: 16},
  summary: {flexDirection: 'row', flexWrap: 'wrap', gap: 16},
  coverFrame: {borderRadius: 8, overflow: 'hidden', borderWidth: StyleSheet.hairlineWidth},
  cover: {width: '100%', height: '100%'},
  info: {flexGrow: 1, flexShrink: 1, gap: 4, justifyContent: 'center'},
  tileCard: {flexGrow: 1, padding: 0, gap: 0, overflow: 'hidden'},
  tileCover: {width: '100%', aspectRatio: COVER_ASPECT},
  tileBody: {flexGrow: 1, padding: 14, gap: 14},
  tileInfo: {justifyContent: 'flex-start'},
  badges: {flexDirection: 'row', flexWrap: 'wrap', gap: 6},
  title: {fontSize: 18, lineHeight: 23},
  position: {flexDirection: 'row', flexWrap: 'wrap', alignItems: 'baseline', columnGap: 8, marginTop: 6},
  positionText: {flexGrow: 1, flexShrink: 1, maxWidth: '100%'},
  percent: {fontSize: 13, lineHeight: 19, fontWeight: '700', fontVariant: ['tabular-nums']},
  progress: {height: 5, borderRadius: 3, overflow: 'hidden', marginTop: 2},
  progressFill: {height: 5, borderRadius: 3},
  actions: {flexDirection: 'row', flexWrap: 'wrap', gap: 10, marginTop: 'auto'},
  primary: {flexGrow: 3, flexBasis: 140}, secondary: {flexGrow: 1},
});
