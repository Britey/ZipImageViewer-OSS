import React, {useState} from 'react';
import {ActivityIndicator, StyleSheet, TextInput, View} from 'react-native';
import type {ImportState} from './protocol';
import {Action, Actions, Label, Meter, usePalette} from './controls';

const phaseLabels: Record<string, string> = {
  preparing: 'Preparing archive', preparingSource: 'Preparing source', copying: 'Copying archive', opening: 'Opening archive',
  waitingForPassword: 'Password required', extracting: 'Extracting images', compressing: 'Compressing images',
  preparingPreviews: 'Preparing previews', preparingPages: 'Preparing pages', cancelling: 'Cancelling import',
  committing: 'Saving archive', completed: 'Import complete', failed: 'Import failed',
};

export function PasswordPrompt({operation, pending, submit, cancel}: {
  operation: ImportState; pending: boolean; submit: (password: string) => void; cancel: () => void;
}) {
  const [password, setPassword] = useState('');
  const [focused, setFocused] = useState(false);
  const c = usePalette();
  const send = () => {if (!pending) {const exact = password; setPassword(''); submit(exact);}};
  return <View style={s.stack}>
    <View style={s.header}><Label variant="overline">Locked archive</Label><Label heading>Archive password</Label>
      <Label muted>{operation.passwordMessage || 'Enter the password for this archive.'}</Label></View>
    <TextInput testID="passwordInput" underlineColorAndroid="transparent" accessibilityLabel="Archive password" secureTextEntry autoCapitalize="none" autoCorrect={false}
      textContentType="none" autoComplete="off" value={password} onChangeText={setPassword} editable={!pending}
      onFocus={() => setFocused(true)} onBlur={() => setFocused(false)} placeholder="Password" placeholderTextColor={c.muted}
      onSubmitEditing={send} returnKeyType="done"
      style={[s.input, {color: c.text, backgroundColor: c.surfaceAlt, borderColor: focused ? c.accent : 'transparent'}]}/>
    <Label variant="caption" muted>Used only for this import. Spaces and Unicode are kept exactly as entered.</Label>
    <Actions>
      <Action title={pending ? 'Submitting…' : 'Unlock archive'} testID="submitPassword" kind="primary" disabled={pending} onPress={send}/>
      {operation.cancellable ? <Action title="Cancel import" kind="plain" disabled={pending} onPress={() => {setPassword(''); cancel();}}/>
        : <Label variant="caption" muted style={s.center}>This stage cannot be cancelled.</Label>}
    </Actions>
  </View>;
}

export function ImportProgress({operation, pending, cancel}: {
  operation: ImportState; pending: boolean; cancel: () => void;
}) {
  const c = usePalette();
  const percent = operation.fraction === null ? null : Math.round(operation.fraction * 100);
  return <View testID="importProgress" style={s.stack}>
    <View style={s.header}><Label variant="overline">Importing</Label>
      <Label heading>{phaseLabels[operation.phase] || operation.phase.replace(/[_-]/g, ' ')}</Label></View>
    {percent === null ? <View style={s.spinner}><ActivityIndicator color={c.accent} size="large"/><Label muted>Working…</Label></View>
      : <View style={s.meter}><View style={s.meterLabel}><Label muted variant="caption">This stage</Label><Label variant="caption" style={s.percent}>{percent}%</Label></View>
        <Meter fraction={operation.fraction ?? 0} height={8}/></View>}
    <Label variant="caption" muted>Keep the app open while the archive is prepared.</Label>
    {operation.cancellable ? <Actions><Action title={pending ? 'Requesting cancellation…' : 'Cancel import'} kind="plain" disabled={pending} onPress={cancel}/></Actions>
      : <View style={[s.note, {backgroundColor: c.surfaceAlt}]}><Label variant="caption" muted>{operation.phase === 'cancelling' ? 'Cancellation is pending. Waiting for native work to finish.' : 'This stage cannot be cancelled. Please wait for it to finish.'}</Label></View>}
  </View>;
}
const s = StyleSheet.create({stack: {gap: 16}, header: {gap: 6},
  input: {fontSize: 17, minHeight: 52, paddingHorizontal: 16, paddingVertical: 12, borderRadius: 14, borderWidth: 1.5},
  center: {textAlign: 'center'}, spinner: {alignItems: 'center', gap: 12, paddingVertical: 12},
  meter: {gap: 8, paddingVertical: 4}, meterLabel: {flexDirection: 'row', justifyContent: 'space-between'},
  percent: {fontWeight: '700', fontVariant: ['tabular-nums']}, note: {padding: 12, borderRadius: 12}});
