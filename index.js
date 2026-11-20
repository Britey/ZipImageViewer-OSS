import {AppRegistry} from 'react-native';
import App from './App';
AppRegistry.registerComponent('ZipImageViewer', () => App);

import {SafeAreaProvider} from 'react-native-safe-area-context';
import React from 'react';
import {ReaderApp} from './mobile/src/ReaderApp';
// Leave empty provider space available to the native reader's page gestures.
AppRegistry.registerComponent('ZipImageReader', () => () => <SafeAreaProvider pointerEvents="box-none"><ReaderApp/></SafeAreaProvider>);
