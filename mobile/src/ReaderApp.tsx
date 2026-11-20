import React, {useEffect, useRef, useState} from 'react';
import {ActivityIndicator, BackHandler, FlatList, KeyboardAvoidingView, Modal, Platform, Pressable, ScrollView, StatusBar, StyleSheet, Text, TextInput, View, useWindowDimensions} from 'react-native';
import {SafeAreaProvider, SafeAreaView} from 'react-native-safe-area-context';
import NativeReaderCanvas from '../specs/NativeReaderCanvas';
import NativeArchiveCover from '../specs/NativeArchiveCover';
import type {ReaderAction} from './protocol';
import {Action, Actions, DialogHeader, Gesture, Label, Theme, usePalette} from './controls';
import {ImportProgress, PasswordPrompt} from './ImportPresentation';
import {Settings} from './Settings';
import {PagePosition} from './PagePosition';
import {useNativeLibrary} from './useNativeLibrary';

function ReaderControls() {
  const {snapshot, error, pending, dispatch, retry, dismissError} = useNativeLibrary();
  const r = snapshot?.reader;
  const ui = r?.ui;
  const [jump, setJump] = useState('');
  const {width, fontScale} = useWindowDimensions();
  const c = usePalette();
  const sequence = useRef(0);
  const act = (action: ReaderAction, page?: number, scrubbing = false) => {
    if (!r) {return;}
    sequence.current = Math.max(sequence.current, ui?.sequence ?? -1) + 1;
    void dispatch({type: 'readerAction', readerId: r.id, action, ...(page === undefined ? {} : {page, scrubbing, sequence: sequence.current})});
  };
  useEffect(() => {if (ui?.tool === 'jump') {setJump(String(ui.page));}}, [r?.id, ui?.tool]);
  useEffect(() => {
    const handler = BackHandler.addEventListener('hardwareBackPress', () => {if (r) {act('back'); return true;} return false;});
    return () => handler.remove();
  });
  const problem = error ?? snapshot?.error?.message;
  const operation = snapshot?.import;
  const activeImport = Boolean(operation?.busy || operation?.passwordRequired);
  const modal = Boolean(problem || activeImport || ui?.tool || ui?.noticePending);
  const closeTool = () => {
    if (error) {dismissError();}
    else if (snapshot?.error) {void dispatch({type: 'dismissError', id: snapshot.error.id});}
    else if (activeImport) {if (operation?.cancellable && !pending) {void dispatch({type: 'cancelImport', operationId: operation.id});}}
    else if (ui?.noticePending) {act('acknowledgeNotice');}
    else {act('dismissTool');}
  };
  const number = /^\d+$/.test(jump.trim()) ? Number(jump.trim()) : NaN;
  const valid = Number.isSafeInteger(number) && number >= 1 && number <= (ui?.count ?? 0);
  const jumpTo = () => {if (valid && !pending && !ui?.sorting) {act('seek', number); act('dismissTool');}};
  const columns = Math.max(fontScale > 1.8 ? 1 : 2, Math.floor(Math.min(width - 40, 1100) / (80 + (snapshot?.preferences.thumbnailSize ?? 0.25) * 150)));
  const labelHeight = Math.ceil(28 * fontScale);
  const rowHeight = ((Math.min(width - 40, 1100) - 24) / columns - 16) / 0.7 + 16 + labelHeight;
  const toolChanged = `${r?.id}:${snapshot?.preferences.sortCriterion}:${snapshot?.preferences.descending}`;
  let content: React.ReactNode;
  if (problem) {
    content = <><DialogHeader eyebrow="Reader" tone="danger" title="Unable to complete operation"/><Label muted>{problem}</Label>
      <Actions>{error && <Action title="Retry connection" kind="primary" onPress={retry}/>}<Action title="OK" kind={error ? 'plain' : 'primary'} onPress={closeTool}/></Actions></>;
  } else if (activeImport && operation) {
    content = operation.passwordRequired ? <PasswordPrompt key={`${operation.id}:${operation.passwordMessage ?? ''}`} operation={operation} pending={pending}
      submit={password => {void dispatch({type: 'submitPassword', operationId: operation.id, password});}}
      cancel={closeTool}/> : <ImportProgress operation={operation} pending={pending} cancel={closeTool}/>;
  } else if (ui?.noticePending) {
    content = <><DialogHeader eyebrow="Heads up" title={ui.temporary ? 'Reading a temporary copy' : 'Cache cleanup'}/>
      <Label muted>{ui.notice ?? 'This archive exceeds your cache limit. Its extracted pages will be removed when you close the reader. Your original archive stays unchanged.'}</Label>
      <Actions><Action title="Continue reading" kind="primary" testID="readerNoticeDone" onPress={closeTool}/></Actions></>;
  } else if (ui?.tool === 'jump') {
    content = <><DialogHeader eyebrow="Navigate" title="Go to page"/><Label muted>Enter a whole number from 1 to {ui.count}.</Label>
      <View style={[s.jumpField, {backgroundColor: c.surfaceAlt, borderColor: valid ? 'transparent' : c.danger}]}>
        <TextInput testID="pageNumberInput" underlineColorAndroid="transparent" accessibilityLabel="Page number" value={jump} onChangeText={setJump} keyboardType="number-pad"
          selectTextOnFocus autoFocus returnKeyType="go" onSubmitEditing={jumpTo} style={[s.input, {color: c.text}]} />
        <Text style={[s.jumpTotal, {color: c.muted}]}>of {ui.count}</Text>
      </View>
      {!valid && <Label variant="caption" style={{color: c.danger}}>Choose a page from 1 to {ui.count}.</Label>}
      <Actions><Action title="Go" testID="confirmPageJump" disabled={!valid || pending || ui.sorting} kind="primary" onPress={jumpTo}/>
        <Action title="Cancel" kind="plain" onPress={closeTool}/></Actions></>;
  } else if (ui?.tool === 'settings' && snapshot) {
    content = <Settings snapshot={snapshot} dispatch={dispatch} disabled={pending || Boolean(ui.sorting)}
      readerOnly showHelp={() => act('openHelp')} clearArchives={() => {}}/>;
  } else if (ui?.tool === 'help') {
    content = <><DialogHeader eyebrow="Help" title="Reader gestures"/>
      <Gesture title="Turn pages" text="Tap either side or swipe. Reverse reading direction swaps these actions."/>
      <Gesture title="Zoom" text="Pinch to zoom and drag to pan. Double tap changes zoom when enabled in Settings."/>
      <Gesture title="Controls" text="Touch and hold the image to show or hide controls. The center tap can do the same. Back shows hidden controls before returning to the library."/>
      <Actions><Action title="Back to settings" onPress={() => act('openSettings')}/></Actions></>;
  }
  const sheetTool = !problem && !activeImport && !ui?.noticePending ? ui?.tool : undefined;
  const showSlider = Boolean(snapshot?.preferences.showSlider);
  return <View pointerEvents="box-none" style={s.root}>
    {Platform.OS === 'android' && <StatusBar hidden/>}
    {Platform.OS === 'android' && r && <NativeReaderCanvas key={r.id} readerId={r.id} style={StyleSheet.absoluteFill} testID="readerCanvas"/>}
    {!ui && <View pointerEvents="none" style={s.loading}><View style={s.loadingChip}><ActivityIndicator color="white"/></View></View>}
    {ui && <SafeAreaView pointerEvents="box-none" style={s.root}>
      {ui.controls && <>
        <View pointerEvents="box-none" style={s.top}>
          <ReaderButton title="‹  Library" label="Back to library" testID="readerClose" onPress={() => act('close')}/>
          <View pointerEvents="box-none" style={s.actions}>{snapshot?.preferences.showRotationButtons && <>
            <ReaderButton symbol title="↶" label="Rotate image counterclockwise 90 degrees" testID="readerRotateCounterclockwise" disabled={ui.sorting || ui.displayedPage !== ui.page || ui.failed} onPress={() => act('rotateCounterclockwise')}/>
            <ReaderButton symbol title="↷" label="Rotate image clockwise 90 degrees" testID="readerRotateClockwise" disabled={ui.sorting || ui.displayedPage !== ui.page || ui.failed} onPress={() => act('rotateClockwise')}/></>}<ReaderButton title="Settings" label="Reader settings" testID="readerSettings" onPress={() => act('openSettings')}/>
            <ReaderButton title="Hide" label="Hide controls" testID="readerHide" onPress={() => act('toggleControls')}/></View>
        </View>
        <View pointerEvents="box-none" style={s.bottom}>
          {ui.detailFailed && <ReaderButton title="Retry zoom detail" label="Retry zoom detail" testID="readerDetailRetry" onPress={() => act('retryDetail')}/>}
          <View style={[s.transport, showSlider ? s.transportWide : s.transportNarrow]}>
            <ReaderButton bare title={snapshot?.preferences.showCount ? `${ui.page} / ${ui.count}` : '#'} label="Go to page" testID="readerPageButton"
              value={`Current page ${ui.page} of ${ui.count}`} disabled={ui.sorting || ui.count === 0} onPress={() => act('openJump')}/>
            {showSlider && <PagePosition key={r?.id} page={ui.page} count={ui.count} disabled={ui.sorting}
              select={(page, scrubbing) => act('seek', page, scrubbing)}/>}
            <ReaderButton bare title="Pages" label="All pages" testID="readerPages" disabled={ui.sorting || ui.count === 0} onPress={() => act('openPages')}/>
          </View>
        </View>
      </>}
      {ui.failed && <View style={s.failure}><Text style={s.failureTitle}>This page cannot be displayed</Text>
        <ReaderButton title="Retry" label="Retry page" testID="readerRetry" onPress={() => act('retry')}/></View>}
    </SafeAreaView>}
    <Modal visible={modal} transparent animationType="fade" onRequestClose={closeTool} statusBarTranslucent
      supportedOrientations={['portrait', 'portrait-upside-down', 'landscape']}>
      <SafeAreaProvider>
      <SafeAreaView style={[s.scrim, {backgroundColor: c.scrim}]}><KeyboardAvoidingView behavior={Platform.OS === 'ios' ? 'padding' : 'height'}
        style={[s.sheet, {backgroundColor: sheetTool === 'settings' || sheetTool === 'pages' ? c.background : c.surface, borderColor: c.line}, sheetTool === 'pages' && s.overview, sheetTool === 'jump' && s.compactSheet]}>
        {sheetTool === 'settings' && <View style={[s.overviewHeader, {borderBottomColor: c.line}]}>
          <View style={{flex: 1}}><Label heading>Reader settings</Label></View><Action title="Done" compact kind="primary" testID="readerSettingsDone" onPress={closeTool}/>
        </View>}
        {sheetTool === 'pages' && r ? <View style={{flex: 1}}>
          <View style={[s.overviewHeader, {borderBottomColor: c.line}]}><View style={{flex: 1}}><Label heading>All pages</Label>
            <Label variant="caption" muted>Page {ui!.page} of {ui!.count}</Label></View>
            <Action title="Done" compact kind="primary" testID="readerPagesDone" onPress={closeTool}/></View>
          <FlatList key={`${columns}:${toolChanged}`} testID="thumbnailGrid" numColumns={columns} data={Array.from({length: ui!.count}, (_, i) => i)}
            windowSize={5} initialNumToRender={columns * 3} maxToRenderPerBatch={columns * 3}
            keyExtractor={i => String(i)} initialScrollIndex={Math.floor(Math.max(0, ui!.page - 1) / columns)}
            getItemLayout={(_, index) => ({length: rowHeight,
              offset: (rowHeight) * index, index})}
            contentContainerStyle={{padding: 12}} renderItem={({item}) => {
              const current = ui!.page === item + 1;
              return <Pressable testID={`thumbnail_${item}`} accessibilityRole="button"
                accessibilityLabel={`Open page ${item + 1}`} accessibilityState={{selected: current, disabled: ui!.sorting || pending}}
                disabled={ui!.sorting || pending} onPress={() => {act('seek', item + 1); act('dismissTool');}}
                style={({pressed}) => [s.thumbnail, {width: `${100 / columns}%`, borderColor: current ? c.accent : 'transparent', backgroundColor: current ? c.accentSoft : 'transparent', opacity: pressed ? 0.7 : 1}]}>
                <View style={[s.thumbnailImage, {backgroundColor: c.surfaceAlt}]}>
                  <NativeArchiveCover archiveId="" readerId={r.id} pageIndex={item} accessible={false} style={{width: '100%', aspectRatio: 0.7}}/>
                </View>
                <Text style={[s.pageLabel, {color: current ? c.accent : c.muted, height: labelHeight, fontWeight: current ? '700' : '500'}]} numberOfLines={1}>{item + 1}</Text>
              </Pressable>;
            }}/>
        </View> : <ScrollView keyboardShouldPersistTaps="handled" contentContainerStyle={s.modalContent}>
          <View accessibilityViewIsModal style={{gap: 16}}>{content}</View></ScrollView>}
      </KeyboardAvoidingView></SafeAreaView>
      </SafeAreaProvider>
    </Modal>
  </View>;
}
function ReaderButton({title, label, value, testID, onPress, disabled = false, bare = false, symbol = false}: {
  title: string; label: string; value?: string; testID: string; onPress: () => void; disabled?: boolean; bare?: boolean; symbol?: boolean;
}) {
  return <Pressable testID={testID} accessibilityRole="button" accessibilityLabel={label}
    accessibilityValue={value ? {text: value} : undefined} accessibilityState={{disabled}} disabled={disabled} onPress={onPress}
    style={({pressed}) => [s.button, bare ? s.bareButton : s.floatingButton, symbol && s.symbolButton, {opacity: disabled ? 0.4 : 1}, pressed && s.pressed]}>
    <Text numberOfLines={1} maxFontSizeMultiplier={1.5} style={[s.buttonText, symbol && s.symbolText]}>{title}</Text></Pressable>;
}
export function ReaderApp() {return <Theme appearance="dark"><ReaderControls/></Theme>;}
const chrome = 'rgba(16,18,24,0.78)';
const chromeLine = 'rgba(255,255,255,0.10)';
const s = StyleSheet.create({root: {flex: 1}, loading: {position: 'absolute', top: 0, bottom: 0, left: 0, right: 0, justifyContent: 'center', alignItems: 'center'},
  loadingChip: {width: 56, height: 56, borderRadius: 28, backgroundColor: chrome, justifyContent: 'center', alignItems: 'center'},
  top: {flexDirection: 'row', flexWrap: 'wrap', justifyContent: 'space-between', alignItems: 'center', padding: 8, gap: 8},
  actions: {flexDirection: 'row', flexWrap: 'wrap', maxWidth: '100%', marginLeft: 'auto', gap: 8},
  bottom: {position: 'absolute', bottom: 8, left: 8, right: 8, alignItems: 'center', gap: 8},
  transport: {flexDirection: 'row', alignItems: 'center', gap: 2, padding: 4, borderRadius: 28, backgroundColor: chrome, borderWidth: StyleSheet.hairlineWidth, borderColor: chromeLine},
  transportWide: {maxWidth: 760, width: '100%'}, transportNarrow: {alignSelf: 'center'},
  button: {minHeight: 48, minWidth: 48, maxWidth: 160, borderRadius: 24, paddingHorizontal: 16, justifyContent: 'center'},
  symbolButton: {width: 48, paddingHorizontal: 0}, symbolText: {fontSize: 24},
  floatingButton: {backgroundColor: chrome, borderWidth: StyleSheet.hairlineWidth, borderColor: chromeLine},
  bareButton: {backgroundColor: 'transparent'}, pressed: {backgroundColor: 'rgba(255,255,255,0.14)'},
  buttonText: {color: 'white', fontSize: 15, fontWeight: '600', textAlign: 'center', fontVariant: ['tabular-nums']},
  failure: {position: 'absolute', alignSelf: 'center', top: '38%', gap: 14, alignItems: 'center', padding: 20, borderRadius: 20, backgroundColor: chrome},
  failureTitle: {color: 'white', fontSize: 16, fontWeight: '600'},
  scrim: {flex: 1, justifyContent: 'center', padding: 20},
  sheet: {width: '100%', maxWidth: 680, maxHeight: '95%', alignSelf: 'center', borderRadius: 24, overflow: 'hidden', borderWidth: StyleSheet.hairlineWidth},
  compactSheet: {maxWidth: 440},
  overview: {maxWidth: 1100, height: '95%'}, modalContent: {padding: 24},
  overviewHeader: {paddingHorizontal: 20, paddingVertical: 14, gap: 16, flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center', borderBottomWidth: StyleSheet.hairlineWidth},
  thumbnail: {padding: 6, borderWidth: 2, borderRadius: 12}, thumbnailImage: {borderRadius: 6, overflow: 'hidden'},
  pageLabel: {fontSize: 14, height: 28, lineHeight: 28, textAlign: 'center', fontVariant: ['tabular-nums']},
  jumpField: {flexDirection: 'row', alignItems: 'center', borderRadius: 14, borderWidth: 1.5, paddingHorizontal: 16},
  input: {flex: 1, minWidth: 0, fontSize: 28, fontWeight: '700', minHeight: 60, paddingVertical: 8, fontVariant: ['tabular-nums']},
  jumpTotal: {fontSize: 18, fontWeight: '500', marginLeft: 8},
});
