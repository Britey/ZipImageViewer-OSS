import {useCallback, useEffect, useRef, useState} from 'react';
import {TurboModuleRegistry} from 'react-native';
import type {Spec} from '../specs/NativeZipImageViewer';
import type {Command, Snapshot} from './protocol';
import {connectNative} from './client';

export function useNativeLibrary() {
  const [snapshot, setSnapshot] = useState<Snapshot | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [attempt, setAttempt] = useState(0);
  const [pending, setPending] = useState(0);
  const connection = useRef<ReturnType<typeof connectNative> | null>(null);
  const generation = useRef(0);
  useEffect(() => {
    const ticket = ++generation.current;
    setError(null);
    setPending(0);
    try {
      const native = TurboModuleRegistry.get<Spec>('ZipImageViewer');
      if (!native) {throw new Error('The native archive service is unavailable. Restart the app or retry.');}
      const client = connectNative(native, s => {
        if (generation.current === ticket) {setSnapshot(s); setError(null);}
      }, message => {if (generation.current === ticket) {setError(message);}});
      connection.current = client;
      return () => {generation.current++; connection.current = null; client.dispose();};
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Unable to connect to the archive service.');
      return () => {generation.current++;};
    }
  }, [attempt]);
  const dispatch = useCallback(async (command: Command) => {
    const ticket = generation.current;
    const client = connection.current;
    if (!client) {return false;}
    setPending(n => n + 1);
    const result = await client.dispatch(command);
    if (generation.current === ticket) {setPending(n => Math.max(0, n - 1));}
    return result;
  }, []);
  return {snapshot, error, pending: pending > 0, dispatch,
    retry: () => {setSnapshot(null); setAttempt(n => n + 1);},
    dismissError: () => setError(null)};
}
