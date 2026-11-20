import React from 'react';
import {Platform, StatusBar, useColorScheme} from 'react-native';
import {SafeAreaProvider} from 'react-native-safe-area-context';
import {LibraryApp} from './mobile/src/LibraryApp';
import {Theme} from './mobile/src/controls';

export default function App() {
  const dark = useColorScheme() === 'dark';
  // iOS keeps controller-based status bars so its retained reader can hide them.
  return <SafeAreaProvider><Theme>{Platform.OS === 'android' && <StatusBar barStyle={dark ? 'light-content' : 'dark-content'}/>}<LibraryApp/></Theme></SafeAreaProvider>;
}
