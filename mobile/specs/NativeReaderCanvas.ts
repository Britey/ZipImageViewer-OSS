import type {HostComponent, ViewProps} from 'react-native';
import {codegenNativeComponent} from 'react-native';
interface NativeProps extends ViewProps { readerId: string; }
export default codegenNativeComponent<NativeProps>('ZIVReaderCanvas', {excludedPlatforms: ['iOS']}) as HostComponent<NativeProps>;
