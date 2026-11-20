import type {HostComponent, ViewProps} from 'react-native';
import type {Int32, WithDefault} from 'react-native/Libraries/Types/CodegenTypes';
import {codegenNativeComponent} from 'react-native';

interface NativeProps extends ViewProps {
  archiveId: string;
  readerId?: WithDefault<string, ''>;
  pageIndex?: WithDefault<Int32, 0>;
}

/** Native decoders own thumbnail bytes and files; React receives only archive identity. */
export default codegenNativeComponent<NativeProps>('ZIVArchiveCover') as HostComponent<NativeProps>;
