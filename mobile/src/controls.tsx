import React, {createContext, useContext} from 'react';
import {Platform, Pressable, StyleSheet, Switch, Text, View, useColorScheme, useWindowDimensions} from 'react-native';
import type {StyleProp, TextStyle, ViewStyle} from 'react-native';

const light = {
  background: '#F5EEE2', surface: '#FFFBF4', surfaceAlt: '#EEE4D3', text: '#2B211A', muted: '#6E5F52', line: '#E3D6C2',
  accent: '#A34B27', accentSoft: 'rgba(163,75,39,0.12)', accentText: '#FFF8F0', danger: '#A3303F', dangerSoft: 'rgba(163,48,63,0.10)',
  track: '#E2D4BE', scrim: 'rgba(43,30,20,0.46)',
};
const dark: typeof light = {
  background: '#1B1613', surface: '#26201B', surfaceAlt: '#332A23', text: '#F3EADF', muted: '#B8A897', line: '#3E342C',
  accent: '#E5A060', accentSoft: 'rgba(229,160,96,0.16)', accentText: '#2A1A0C', danger: '#F0938A', dangerSoft: 'rgba(240,147,138,0.14)',
  track: '#473B31', scrim: 'rgba(12,8,5,0.68)',
};
export const serif = Platform.select({ios: 'Georgia', android: 'serif', default: undefined});
type Palette = typeof light;
const PaletteContext = createContext<Palette>(light);
// Android preferences are stored as Float32; their JSON Double values carry
// rounding noise (for example 0.3f becomes 0.30000001192092896).
const sameChoice = (left: string | number, right: string | number) =>
  typeof left === 'number' && typeof right === 'number' ? Math.abs(left - right) < 1e-6 : left === right;
export function Theme({children, appearance}: {children: React.ReactNode; appearance?: 'dark' | 'light'}) {
  const system = useColorScheme();
  return <PaletteContext.Provider value={(appearance ?? system) === 'dark' ? dark : light}>{children}</PaletteContext.Provider>;
}
export const usePalette = () => useContext(PaletteContext);

type Variant = 'title' | 'heading' | 'body' | 'caption' | 'overline';
export function Label({children, muted = false, heading = false, variant, numberOfLines, style}: {
  children: React.ReactNode; muted?: boolean; heading?: boolean; variant?: Variant; numberOfLines?: number; style?: StyleProp<TextStyle>;
}) {
  const colors = usePalette();
  const kind = variant ?? (heading ? 'heading' : 'body');
  return <Text accessibilityRole={heading || kind === 'title' || kind === 'heading' ? 'header' : undefined} numberOfLines={numberOfLines}
    style={[styles.text, styles[kind], {color: muted || kind === 'overline' ? colors.muted : colors.text}, style]}>{children}</Text>;
}

export function Action({title, onPress, disabled = false, kind = 'secondary', testID, icon, compact = false, style}: {
  title: string; onPress: () => void; disabled?: boolean; kind?: 'primary' | 'secondary' | 'danger' | 'plain'; testID?: string;
  /** Short glyph shown instead of the title; the title stays the accessible name. */
  icon?: string; compact?: boolean; style?: StyleProp<ViewStyle>;
}) {
  const c = usePalette();
  const background = kind === 'primary' ? c.accent : kind === 'danger' ? c.dangerSoft : kind === 'plain' ? 'transparent' : c.accentSoft;
  const color = kind === 'primary' ? c.accentText : kind === 'danger' ? c.danger : c.accent;
  return <Pressable testID={testID} accessibilityRole="button" accessibilityLabel={title} accessibilityState={{disabled}} disabled={disabled} onPress={onPress}
    hitSlop={compact ? 4 : undefined}
    style={({pressed}) => [styles.action, compact && styles.compact, icon !== undefined && styles.iconAction,
      {backgroundColor: background, opacity: disabled ? 0.4 : pressed ? 0.7 : 1}, style]}>
    <Text numberOfLines={icon ? 1 : undefined} style={[styles.actionText, icon !== undefined && styles.iconText, {color}]}>{icon ?? title}</Text>
  </Pressable>;
}

/** Stacked dialog buttons, primary first. */
export function Actions({children}: {children: React.ReactNode}) {
  return <View style={styles.actions}>{children}</View>;
}

export function Toggle({title, detail, value, onChange, disabled}: {
  title: string; detail?: string; value: boolean; onChange: (value: boolean) => void; disabled: boolean;
}) {
  const c = usePalette();
  return <View style={[styles.row, {opacity: disabled ? 0.55 : 1}]}><View style={styles.grow}><Label>{title}</Label>{detail && <Label variant="caption" muted>{detail}</Label>}</View>
    <Switch accessibilityLabel={title} value={value} onValueChange={onChange} disabled={disabled}
      trackColor={{false: c.track, true: Platform.OS === 'android' ? c.accentSoft : c.accent}}
      thumbColor={Platform.OS === 'android' ? value ? c.accent : c.surface : undefined} ios_backgroundColor={c.track}/></View>;
}

/** Segmented control for short option sets; wraps into chips for longer ones or enlarged text. */
export function Choices<T extends string | number>({title, options, value, onChange, disabled = false}: {
  title: string; options: Array<{value: T; title: string}>; value: T; onChange: (value: T) => void; disabled?: boolean;
}) {
  const c = usePalette();
  const {fontScale} = useWindowDimensions();
  const segmented = fontScale <= 1.3 && (options.length <= 3 || (options.length <= 5 && options.every(option => option.title.length <= 4)));
  return <View style={styles.section}><Label variant="caption" muted>{title}</Label>
    <View style={segmented ? [styles.segments, {backgroundColor: c.surfaceAlt}] : styles.wrap}>{options.map(option => {
      const selected = sameChoice(value, option.value);
      return <Pressable key={option.value}
        accessibilityRole="radio" accessibilityLabel={`${title}: ${option.title}`} accessibilityState={{selected, disabled}}
        disabled={disabled} onPress={() => onChange(option.value)}
        style={({pressed}) => [segmented ? styles.segment : [styles.chip, {borderColor: selected ? c.accent : c.line}],
          {backgroundColor: selected ? c.accent : segmented ? 'transparent' : c.surface, opacity: disabled ? 0.45 : pressed && !selected ? 0.6 : 1}]}>
        <Text numberOfLines={segmented ? 1 : undefined} adjustsFontSizeToFit={segmented} style={[styles.choiceText, {color: selected ? c.accentText : c.text}]}>{option.title}</Text>
      </Pressable>;
    })}</View></View>;
}

export function Card({children, style}: {children: React.ReactNode; style?: StyleProp<ViewStyle>}) {
  const c = usePalette();
  return <View style={[styles.card, {backgroundColor: c.surface, borderColor: c.line}, style]}>{children}</View>;
}

/** Grouped settings card: overline title, hairline-separated rows and an optional footnote. */
export function Section({title, footer, children}: {title: string; footer?: React.ReactNode; children: React.ReactNode}) {
  const c = usePalette();
  const rows = React.Children.toArray(children).filter(Boolean);
  return <View style={styles.group}>
    <Label heading variant="overline" style={styles.groupTitle}>{title}</Label>
    <View style={[styles.groupCard, {backgroundColor: c.surface, borderColor: c.line}]}>{rows.map((row, index) => <React.Fragment key={index}>
      {index > 0 && <View style={[styles.divider, {backgroundColor: c.line}]}/>}{row}
    </React.Fragment>)}</View>
    {footer && <View style={styles.groupFooter}>{footer}</View>}
  </View>;
}

export function Badge({title, tone = 'neutral'}: {title: string; tone?: 'neutral' | 'accent' | 'danger'}) {
  const c = usePalette();
  const color = tone === 'accent' ? c.accent : tone === 'danger' ? c.danger : c.muted;
  return <View style={[styles.badge, {backgroundColor: tone === 'accent' ? c.accentSoft : tone === 'danger' ? c.dangerSoft : c.surfaceAlt}]}>
    <Text style={[styles.badgeText, {color}]}>{title}</Text>
  </View>;
}

export function Meter({fraction, tone = 'accent', height = 6}: {fraction: number; tone?: 'accent' | 'danger'; height?: number}) {
  const c = usePalette();
  return <View style={{height, borderRadius: height / 2, overflow: 'hidden', backgroundColor: c.track}}>
    <View style={{height, width: `${Math.min(1, Math.max(0, fraction)) * 100}%`, borderRadius: height / 2, backgroundColor: tone === 'danger' ? c.danger : c.accent}}/>
  </View>;
}

/** Two-column key/value line used in dialogs. */
export function Detail({title, value}: {title: string; value: React.ReactNode}) {
  return <View style={styles.detail}><Label muted style={styles.detailKey}>{title}</Label>
    <Label style={styles.detailValue}>{value}</Label></View>;
}

export function DialogHeader({eyebrow, title, tone}: {eyebrow?: string; title: string; tone?: 'danger'}) {
  const c = usePalette();
  return <View style={styles.dialogHeader}>{eyebrow && <Label variant="overline" style={tone === 'danger' ? {color: c.danger} : undefined}>{eyebrow}</Label>}
    <Label heading>{title}</Label></View>;
}

/** Help entry: short bold title with an explanatory caption. */
export function Gesture({title, text}: {title: string; text: string}) {
  const c = usePalette();
  return <View style={styles.gesture}><View style={[styles.gestureMark, {backgroundColor: c.accent}]}/>
    <View style={styles.grow}><Label style={styles.gestureTitle}>{title}</Label><Label variant="caption" muted>{text}</Label></View></View>;
}

export const formatBytes = (bytes: number) => bytes >= 1e9 ? `${(bytes / 1e9).toFixed(1)} GB` : bytes >= 1e6 ? `${(bytes / 1e6).toFixed(1)} MB` : bytes >= 1000 ? `${(bytes / 1000).toFixed(1)} KB` : `${Math.round(bytes)} B`;
export const styles = StyleSheet.create({
  text: {fontSize: 16, lineHeight: 23},
  title: {fontFamily: serif, fontSize: 32, lineHeight: 39, fontWeight: '700'},
  heading: {fontFamily: serif, fontSize: 21, lineHeight: 27, fontWeight: '700'},
  body: {},
  caption: {fontSize: 13, lineHeight: 19},
  overline: {fontSize: 12, lineHeight: 16, fontWeight: '700', letterSpacing: 1, textTransform: 'uppercase'},
  actionText: {fontSize: 16, lineHeight: 21, fontWeight: '600', textAlign: 'center'},
  iconText: {fontSize: 22, lineHeight: 24, fontWeight: '500'},
  action: {minHeight: 50, paddingHorizontal: 18, paddingVertical: 12, borderRadius: 14, justifyContent: 'center', alignItems: 'center'},
  compact: {minHeight: 40, paddingHorizontal: 14, paddingVertical: 8, borderRadius: 20},
  iconAction: {minWidth: 44, minHeight: 44, paddingHorizontal: 0, paddingVertical: 0, borderRadius: 22},
  actions: {gap: 10, marginTop: 8},
  row: {flexDirection: 'row', alignItems: 'center', gap: 16, minHeight: 52, paddingVertical: 8}, grow: {flex: 1},
  wrap: {flexDirection: 'row', flexWrap: 'wrap', gap: 8}, section: {gap: 8, paddingVertical: 12},
  segments: {flexDirection: 'row', padding: 3, borderRadius: 12, gap: 3},
  segment: {flex: 1, minHeight: 40, paddingHorizontal: 6, borderRadius: 9, justifyContent: 'center', alignItems: 'center'},
  chip: {minHeight: 40, minWidth: 64, maxWidth: '100%', paddingHorizontal: 14, borderRadius: 20, borderWidth: 1, justifyContent: 'center', alignItems: 'center'},
  choiceText: {fontSize: 15, fontWeight: '600', textAlign: 'center'},
  card: {padding: 16, borderRadius: 18, borderWidth: StyleSheet.hairlineWidth, gap: 12},
  group: {gap: 8},
  groupTitle: {paddingHorizontal: 16},
  groupCard: {paddingHorizontal: 16, borderRadius: 16, borderWidth: StyleSheet.hairlineWidth, paddingVertical: 2},
  groupFooter: {paddingHorizontal: 16, gap: 6},
  divider: {height: StyleSheet.hairlineWidth},
  badge: {maxWidth: '100%', paddingHorizontal: 8, paddingVertical: 3, borderRadius: 6, alignSelf: 'flex-start'},
  badgeText: {fontSize: 11, lineHeight: 14, fontWeight: '700', letterSpacing: 0.5},
  detail: {flexDirection: 'row', gap: 12, paddingVertical: 4},
  dialogHeader: {gap: 4},
  gesture: {flexDirection: 'row', gap: 12}, gestureMark: {width: 4, borderRadius: 2, marginVertical: 3}, gestureTitle: {fontWeight: '600'},
  detailKey: {flex: 2, fontSize: 15}, detailValue: {flex: 3, fontSize: 15, textAlign: 'right'},
});
