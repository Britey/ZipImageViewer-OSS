import React, {useEffect, useState} from 'react';
import {ActivityIndicator, BackHandler, FlatList, KeyboardAvoidingView, Modal, Platform, ScrollView, StyleSheet, TextInput, View, useWindowDimensions} from 'react-native';
import {SafeAreaView} from 'react-native-safe-area-context';
import {ImportProgress, PasswordPrompt} from './ImportPresentation';
import NativeArchiveCover from '../specs/NativeArchiveCover';
import {Action, Actions, Badge, Card, Detail, DialogHeader, Gesture, Label, formatBytes, styles as controls, usePalette} from './controls';
import {ArchiveCard, openedDate, readingPosition} from './ArchiveCard';
import {Settings} from './Settings';
import {useNativeLibrary} from './useNativeLibrary';

type LocalModal = {type: 'details'; id: string} | {type: 'remove'; id: string} | {type: 'clear'} | {type: 'help'} | null;
export function LibraryApp() {
  const {snapshot, error, pending, dispatch, retry, dismissError} = useNativeLibrary();
  const [settings, setSettings] = useState(false);
  const [search, setSearch] = useState('');
  const [local, setLocal] = useState<LocalModal>(null);
  const c = usePalette();
  const {width, fontScale} = useWindowDimensions();
  const columns = fontScale > 1.3 ? 1 : width >= 1120 ? 3 : width >= 720 ? 2 : 1;
  const operation = snapshot?.import;
  useEffect(() => {
    if (snapshot?.reader?.id) {setSettings(false); setLocal(null);}
  }, [snapshot?.reader?.id]);
  const busy = pending || Boolean(snapshot?.busy) || Boolean(operation?.busy) || Boolean(snapshot?.reader);
  const activeImport = Boolean(operation?.busy || operation?.passwordRequired);
  // The reader root owns presentation while a native reading session is open.
  const modalType = snapshot?.reader ? undefined : error ? 'bridgeError' : snapshot?.error ? 'nativeError' : activeImport ? operation?.passwordRequired ? 'password' : 'progress'
    : snapshot?.cachePreview ? 'quota' : local?.type;
  const closeModal = () => {
    if (modalType === 'bridgeError') {dismissError();}
    else if (modalType === 'nativeError' && snapshot?.error && !pending) {void dispatch({type: 'dismissError', id: snapshot.error.id});}
    else if ((modalType === 'password' || modalType === 'progress') && operation?.cancellable && !pending) {
      void dispatch({type: 'cancelImport', operationId: operation.id});
    } else if (modalType === 'quota' && !pending) {void dispatch({type: 'dismissCachePreview'});}
    else if (!activeImport && !snapshot?.error && !snapshot?.cachePreview && !error) {setLocal(null);}
  };
  useEffect(() => {
    const subscription = BackHandler.addEventListener('hardwareBackPress', () => {
      if (modalType) {closeModal(); return true;}
      if (settings) {setSettings(false); return true;}
      return false;
    });
    return () => subscription.remove();
  });
  const selected = local && 'id' in local ? snapshot?.archives.find(a => a.id === local.id) : undefined;
  const query = searchKey(search.trim());
  const filtered = snapshot?.archives.filter(a => searchKey(a.title).includes(query)) ?? [];
  const mutate = async (type: 'removeArchive' | 'clearArchives') => {
    const success = type === 'removeArchive' && local && 'id' in local ? await dispatch({type, id: local.id}) : await dispatch({type: 'clearArchives'});
    if (success) {setLocal(null);}
  };
  const preview = snapshot?.cachePreview;
  let modal: React.ReactNode;
  if (modalType === 'bridgeError') {
    modal = <><DialogHeader eyebrow="Connection" title="Connection problem" tone="danger"/><Label muted>{error}</Label>
      <Actions><Action title="Retry connection" kind="primary" onPress={retry}/>{snapshot && <Action title="Dismiss" kind="plain" onPress={dismissError}/>}</Actions></>;
  } else if (modalType === 'nativeError' && snapshot?.error) {
    modal = <><DialogHeader eyebrow="Something went wrong" title={snapshot.error.title} tone="danger"/><Label muted>{snapshot.error.message}</Label>
      <Actions><Action title="OK" kind="primary" disabled={pending} onPress={closeModal}/></Actions></>;
  } else if (modalType === 'password' && operation) {
    modal = <PasswordPrompt key={`${operation.id}:${operation.passwordMessage ?? ''}`} operation={operation} pending={pending}
      submit={password => {void dispatch({type: 'submitPassword', operationId: operation.id, password});}}
      cancel={() => {void dispatch({type: 'cancelImport', operationId: operation.id});}}/>;
  } else if (modalType === 'progress' && operation) {
    modal = <ImportProgress operation={operation} pending={pending} cancel={closeModal}/>;
  } else if (modalType === 'quota' && preview) {
    modal = <><DialogHeader eyebrow="Storage" title={preview.changed ? 'Storage preview changed' : 'Review storage limits'}/>
      <View style={[s.limits, {backgroundColor: c.surfaceAlt}]}>
        <View style={s.limit}><Label variant="caption" muted>Size limit</Label><Label variant="heading">{formatBytes(preview.limits.maximumBytes)}</Label></View>
        <View style={[s.limitDivider, {backgroundColor: c.line}]}/>
        <View style={s.limit}><Label variant="caption" muted>Archive limit</Label><Label variant="heading">{preview.limits.maximumArchiveCount ?? 'Unlimited'}</Label></View>
      </View>
      <Label muted>{preview.changed ? 'The library changed. Review this updated list before applying.' : 'Native storage has calculated the following impact.'}</Label>
      {preview.victims.length ? <View style={s.victims}>
        <Label variant="overline">Cached copies to remove ({preview.victims.length}){preview.reclaimedBytes !== undefined ? ` · ${formatBytes(preview.reclaimedBytes)}` : ''}</Label>
        <View style={[s.victimList, {borderColor: c.line}]}>{preview.victims.map((v, index) => <View key={v.id} style={[s.victim, index > 0 && {borderTopColor: c.line, borderTopWidth: StyleSheet.hairlineWidth}]}>
          <View style={[s.dot, {backgroundColor: c.danger}]}/><Label style={controls.grow}>{v.title}</Label></View>)}</View>
      </View> : <View style={[s.note, {backgroundColor: c.accentSoft}]}><Label>No cached archives need to be removed.</Label></View>}
      <Label variant="caption" muted>Reading positions are kept when limits remove a cached copy. Open archives stay protected; if they keep storage above the new limits, older copies may be removed after closing. Original source archives stay unchanged.</Label>
      <Actions><Action title="Apply reviewed limits" kind="primary" disabled={pending} onPress={() => {void dispatch({type: 'applyCachePreview', token: preview.token});}}/>
        <Action title="Cancel" kind="plain" disabled={pending} onPress={closeModal}/></Actions></>;
  } else if (modalType === 'details') {
    modal = selected ? <>
      <View style={s.detailsHeader}>
        <View style={[s.detailsCover, {backgroundColor: c.surfaceAlt, borderColor: c.line}]}>
          <NativeArchiveCover archiveId={selected.available ? selected.id : ''} accessible={false} style={s.fill}/>
        </View>
        <View style={[controls.grow, s.detailsTitle]}>
          <View style={s.badges}>{selected.format && <Badge title={selected.format.toUpperCase()}/>}
            <Badge title={selected.available ? 'OFFLINE' : 'UNAVAILABLE'} tone={selected.available ? 'accent' : 'danger'}/></View>
          <Label heading numberOfLines={4}>{selected.title}</Label>
        </View>
      </View>
      <View style={[s.detailList, {backgroundColor: c.surfaceAlt}]}>
        <Detail title="Position" value={readingPosition(selected)}/>
        <Detail title="Progress" value={`${Math.round(selected.progress * 100)}%`}/>
        <Detail title="Pages" value={String(selected.pageCount)}/>
        <Detail title="Size" value={formatBytes(selected.retainedBytes)}/>
        {selected.format && <Detail title="Format" value={selected.format.toUpperCase()}/>}
        <Detail title="Status" value={selected.available ? 'Available offline' : 'Cached images unavailable'}/>
        <Detail title="Last opened" value={openedDate(selected.lastOpenedAt)}/>
      </View>
      <Actions><Action title={selected.available ? 'Open archive' : 'Select archive again'} kind="primary" disabled={busy} onPress={() => {
        setLocal(null); void dispatch(selected.available ? {type: 'openArchive', id: selected.id} : {type: 'pickArchive'});
      }}/><Action title="Remove cached copy…" kind="danger" disabled={busy} onPress={() => setLocal({type: 'remove', id: selected.id})}/>
        <Action title="Done" kind="plain" onPress={() => setLocal(null)}/></Actions></>
      : <><DialogHeader title="Archive not found"/><Label muted>This archive is no longer in the library.</Label><Actions><Action title="Done" kind="primary" onPress={() => setLocal(null)}/></Actions></>;
  } else if (modalType === 'remove' || modalType === 'clear') {
    modal = <><DialogHeader eyebrow="This can’t be undone" tone="danger" title={modalType === 'clear' ? 'Clear cached library?' : 'Remove cached archive?'}/>
      <Label muted>{modalType === 'clear' ? 'All cached archives and their saved reading progress will be removed.' : `The cached copy of “${selected?.title ?? 'this archive'}” and its saved reading progress will be removed.`}</Label>
      <Label variant="caption" muted>Your original source archives remain unchanged.</Label>
      <Actions><Action title={modalType === 'clear' ? 'Clear library' : 'Remove cached copy'} kind="danger" disabled={busy || (modalType === 'remove' && !selected)}
        onPress={() => {void mutate(modalType === 'clear' ? 'clearArchives' : 'removeArchive');}}/>
        <Action title="Cancel" kind="plain" disabled={pending} onPress={() => setLocal(null)}/></Actions></>;
  } else if (modalType === 'help') {
    modal = <><DialogHeader eyebrow="Help" title="Reading your archive"/>
      <Gesture title="Turn pages" text="Tap a page-turn area or swipe. Reading direction and the left tap area width are set in Settings."/>
      <Gesture title="Show controls" text="Tap the center when enabled, or touch and hold the image."/>
      <Gesture title="Zoom" text="Pinch to zoom and drag to pan. Double tap changes zoom when enabled in Settings."/>
      <Gesture title="Navigate" text="Use the slider or page jump to go to a page. Open Pages to browse thumbnails. Reader settings apply while you read."/>
      <Actions><Action title="Done" kind="primary" onPress={() => setLocal(null)}/></Actions></>;
  }
  const count = snapshot?.archives.length ?? 0;
  return <SafeAreaView style={[s.root, {backgroundColor: c.background}]} edges={['top', 'bottom', 'left', 'right']}>
    <View style={[s.header, settings && s.settingsHeader]}><View style={s.headerTitle}>
      <Label variant="overline">{settings ? 'ZipImageViewer' : snapshot?.ready ? `${count} ${count === 1 ? 'archive' : 'archives'} · ${formatBytes(snapshot.cache.retainedBytes)}` : 'ZipImageViewer'}</Label>
      <Label variant="title">{settings ? 'Settings' : 'Library'}</Label></View>
      <Action title={settings ? 'Done' : 'Settings'} testID="openSettings" compact style={s.headerAction} kind={settings ? 'primary' : 'secondary'} onPress={() => setSettings(v => !v)}/></View>
    {!snapshot || !snapshot.ready ? <View style={s.center}><ActivityIndicator size="large" color={c.accent}/><Label muted>Loading your library…</Label>
      <View style={s.centerActions}>{error && <Action title="Retry" kind="primary" onPress={retry}/>}
        {snapshot && !snapshot.ready && <Action title="Retry loading library" disabled={pending} onPress={() => {void dispatch({type: 'refresh'});}}/>}</View></View>
      : settings ? <ScrollView testID="settingsScreen" contentContainerStyle={s.content} keyboardShouldPersistTaps="handled">
        <View style={s.settings}><Settings snapshot={snapshot} dispatch={dispatch} disabled={busy} showHelp={() => setLocal({type: 'help'})} clearArchives={() => setLocal({type: 'clear'})}/></View>
      </ScrollView> : <FlatList key={`library-${columns}`} testID="libraryScreen" numColumns={columns} data={filtered} keyExtractor={a => a.id} contentContainerStyle={s.content} keyboardShouldPersistTaps="handled"
        columnWrapperStyle={columns > 1 ? s.columns : undefined}
        ItemSeparatorComponent={() => <View style={{height: 12}}/>}
        ListHeaderComponent={<View style={s.stack}>
          <View style={s.openRow}><View style={controls.grow}><Action title="Open archive" testID="openArchive" kind="primary" disabled={busy} onPress={() => {void dispatch({type: 'pickArchive'});}}/></View>
            {snapshot.capabilities.pickerPreferences && <View style={controls.grow}><Action title="Open using another file app…" testID="pickArchiveOnce" disabled={busy}
              onPress={() => {void dispatch({type: 'pickArchiveOnce'});}}/></View>}</View>
          {snapshot.archives.length > 0 && <View style={[s.search, {backgroundColor: c.surfaceAlt}]}>
            <View style={[s.searchIcon, {borderColor: c.muted}]}><View style={[s.searchHandle, {backgroundColor: c.muted}]}/></View>
            <TextInput testID="searchArchives" underlineColorAndroid="transparent" accessibilityLabel="Search archives" placeholder={fontScale > 1.3 ? 'Search' : 'Search your library'} placeholderTextColor={c.muted} numberOfLines={1} value={search}
              onChangeText={setSearch} autoCorrect={false} returnKeyType="search" clearButtonMode="while-editing" style={[s.input, {color: c.text}]}/>
          </View>}
          {snapshot.reader && <Card style={{borderColor: c.accent}}><Label variant="overline">Now reading</Label><Label heading numberOfLines={2}>{snapshot.reader.title}</Label>
            <Action title="Return to library" onPress={() => {void dispatch({type: 'closeReader'});}} disabled={pending}/></Card>}
          {snapshot.archives.length > 0 && <Label variant="overline" style={s.listTitle}>{query ? `${filtered.length} of ${snapshot.archives.length}` : 'Your archives'}</Label>}
        </View>}
        ListEmptyComponent={<View style={s.empty}>
          <View style={s.emptyArt} accessible={false}>
            <View style={[s.sheetBack, {backgroundColor: c.surfaceAlt, borderColor: c.line}]}/>
            <View style={[s.sheetFront, {backgroundColor: c.surface, borderColor: c.line}]}>
              <View style={[s.artLine, {backgroundColor: c.accentSoft, width: '70%'}]}/><View style={[s.artBlock, {backgroundColor: c.accentSoft}]}/>
              <View style={[s.artLine, {backgroundColor: c.track, width: '55%'}]}/>
            </View>
          </View>
          <Label heading style={s.emptyText}>{snapshot.archives.length ? 'No matching archives' : 'No archives yet'}</Label>
          <Label muted style={s.emptyText}>{snapshot.archives.length ? 'Try another title or clear your search.' : 'Open a ZIP, CBZ or 7z archive from your files to start reading. Your library and reading progress stay on this device.'}</Label>
          <View style={s.centerActions}>{snapshot.archives.length ? <Action title="Clear search" onPress={() => setSearch('')}/> : <Action title="Open archive" testID="openEmptyArchive" kind="primary" disabled={busy} onPress={() => {void dispatch({type: 'pickArchive'});}}/>}</View>
        </View>}
        renderItem={({item}) => <View style={[columns > 1 && s.archive, {width: `${100 / columns}%`}]}><ArchiveCard archive={item} disabled={busy} details={() => setLocal({type: 'details', id: item.id})}
          open={() => {void dispatch(item.available ? {type: 'openArchive', id: item.id} : {type: 'pickArchive'});}}/></View>}/>}
    <Modal visible={Boolean(modalType)} transparent animationType="fade" onRequestClose={closeModal} supportedOrientations={['portrait', 'portrait-upside-down', 'landscape']}
      onDismiss={() => {if (Platform.OS === 'ios') {void dispatch({type: 'presentationReady'});}}} statusBarTranslucent>
      <SafeAreaView style={[s.scrim, {backgroundColor: c.scrim}]}><KeyboardAvoidingView behavior={Platform.OS === 'ios' ? 'padding' : 'height'} style={s.modalContainer}>
        <ScrollView style={[s.sheet, {backgroundColor: c.surface, borderColor: c.line}]} contentContainerStyle={s.modalContent} keyboardShouldPersistTaps="handled">
          <View accessibilityViewIsModal style={s.stack}>{modal}</View>
        </ScrollView>
      </KeyboardAvoidingView></SafeAreaView>
    </Modal>
  </SafeAreaView>;
}

// UIKit's localized search ignores case and diacritics; Android keeps its existing case-only search.
function searchKey(text: string): string {
  const lower = text.toLocaleLowerCase();
  return Platform.OS === 'ios' ? lower.normalize('NFD').replace(/\p{M}/gu, '') : lower;
}

const s = StyleSheet.create({
  root: {flex: 1}, fill: {width: '100%', height: '100%'},
  header: {paddingHorizontal: 20, paddingTop: 16, paddingBottom: 16, flexDirection: 'row', flexWrap: 'wrap', gap: 12, alignItems: 'flex-end', width: '100%', maxWidth: 1280, alignSelf: 'center'},
  headerTitle: {flexGrow: 1, maxWidth: '100%'}, headerAction: {marginLeft: 'auto'},
  content: {paddingHorizontal: 20, paddingTop: 4, paddingBottom: 40, gap: 12, width: '100%', maxWidth: 1280, alignSelf: 'center'},
  settings: {width: '100%', maxWidth: 720, alignSelf: 'center'}, settingsHeader: {maxWidth: 760},
  columns: {alignItems: 'stretch', marginHorizontal: -6}, archive: {paddingHorizontal: 6},
  stack: {gap: 14, paddingBottom: 4}, center: {flex: 1, justifyContent: 'center', alignItems: 'center', gap: 16, padding: 24},
  centerActions: {gap: 10, alignSelf: 'center', maxWidth: 360, width: '100%'},
  openRow: {flexDirection: 'row', flexWrap: 'wrap', gap: 10},
  search: {flexDirection: 'row', alignItems: 'center', borderRadius: 14, paddingLeft: 14, minHeight: 48},
  searchIcon: {width: 14, height: 14, borderRadius: 7, borderWidth: 2, marginRight: 4},
  searchHandle: {position: 'absolute', width: 6, height: 2, borderRadius: 1, right: -5, bottom: -3, transform: [{rotate: '45deg'}]},
  input: {flex: 1, fontSize: 16, minHeight: 48, paddingHorizontal: 10, paddingVertical: 10},
  listTitle: {marginTop: 8, paddingHorizontal: 4},
  empty: {alignItems: 'center', gap: 10, paddingVertical: 40, paddingHorizontal: 16},
  emptyText: {textAlign: 'center', maxWidth: 420},
  emptyArt: {width: 120, height: 120, marginBottom: 12},
  sheetBack: {position: 'absolute', width: 72, height: 96, left: 14, top: 8, borderRadius: 10, borderWidth: 1, transform: [{rotate: '-9deg'}]},
  sheetFront: {position: 'absolute', width: 72, height: 96, left: 38, top: 16, borderRadius: 10, borderWidth: 1, padding: 10, gap: 7, transform: [{rotate: '5deg'}]},
  artLine: {height: 6, borderRadius: 3}, artBlock: {height: 34, borderRadius: 5},
  scrim: {flex: 1, justifyContent: 'center', padding: 20},
  modalContainer: {width: '100%', maxWidth: 520, maxHeight: '95%', alignSelf: 'center'},
  sheet: {borderRadius: 24, flexGrow: 0, borderWidth: StyleSheet.hairlineWidth}, modalContent: {padding: 24},
  limits: {flexDirection: 'row', borderRadius: 14, padding: 14, gap: 14},
  limit: {flex: 1, gap: 2}, limitDivider: {width: StyleSheet.hairlineWidth},
  victims: {gap: 8}, victimList: {borderWidth: StyleSheet.hairlineWidth, borderRadius: 12, paddingHorizontal: 14},
  victim: {flexDirection: 'row', alignItems: 'center', gap: 10, paddingVertical: 10},
  dot: {width: 6, height: 6, borderRadius: 3},
  note: {padding: 14, borderRadius: 12},
  detailsHeader: {flexDirection: 'row', gap: 16, alignItems: 'center'},
  detailsCover: {width: 88, height: 124, borderRadius: 10, overflow: 'hidden', borderWidth: StyleSheet.hairlineWidth},
  detailsTitle: {gap: 8}, badges: {flexDirection: 'row', gap: 6, flexWrap: 'wrap'},
  detailList: {borderRadius: 14, paddingHorizontal: 14, paddingVertical: 8},
});
