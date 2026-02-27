import { StatusBar } from 'expo-status-bar';
import * as FileSystem from 'expo-file-system';
import { useCallback, useRef, useState } from 'react';
import {
  Alert,
  Platform,
  Pressable,
  SafeAreaView,
  ScrollView,
  StyleSheet,
  Text,
  View,
} from 'react-native';
import {
  getUnzip,
  type UnzipTask,
  type ZipTask,
  type UnzipProgress,
  type ZipProgress,
} from 'react-native-nitro-unzip';

type LogEntry = { id: number; text: string; type: 'info' | 'success' | 'error' };

export default function App() {
  const [logs, setLogs] = useState<LogEntry[]>([]);
  const [progress, setProgress] = useState<number | null>(null);
  const [activeLabel, setActiveLabel] = useState<string | null>(null);
  const activeTask = useRef<UnzipTask | ZipTask | null>(null);
  const logId = useRef(0);

  const log = useCallback((text: string, type: LogEntry['type'] = 'info') => {
    setLogs((prev) => [{ id: logId.current++, text, type }, ...prev]);
  }, []);

  const clearLogs = useCallback(() => {
    setLogs([]);
    setProgress(null);
    setActiveLabel(null);
  }, []);

  const cancel = useCallback(() => {
    if (activeTask.current) {
      activeTask.current.cancel();
      log('Cancelled', 'error');
      activeTask.current = null;
      setActiveLabel(null);
    }
  }, [log]);

  // ── Extract test zip ──────────────────────────────────────────────
  const handleExtract = useCallback(async () => {
    try {
      setProgress(0);
      setActiveLabel('Extracting...');

      const zipUri = `${FileSystem.bundleDirectory ?? FileSystem.documentDirectory}assets/test.zip`;
      const destDir = `${FileSystem.cacheDirectory}extracted/`;

      // Clean previous extraction
      const info = await FileSystem.getInfoAsync(destDir);
      if (info.exists) {
        await FileSystem.deleteAsync(destDir, { idempotent: true });
      }

      log(`Source: ${zipUri}`);
      log(`Destination: ${destDir}`);

      const unzip = getUnzip();
      const task = unzip.extract(zipUri, destDir);
      activeTask.current = task;

      log(`Task created: ${task.taskId}`);

      task.onProgress((p: UnzipProgress) => {
        setProgress(p.progress);
        log(
          `${p.extractedFiles}/${p.totalFiles} files — ${(p.progress * 100).toFixed(0)}% — ${p.speed.toFixed(0)} files/sec`,
        );
      });

      const result = await task.await();
      activeTask.current = null;
      setProgress(1);
      setActiveLabel(null);

      log(
        `Done: ${result.extractedFiles} files in ${result.duration.toFixed(0)}ms (${result.averageSpeed.toFixed(0)} files/sec)`,
        'success',
      );

      // List extracted files
      const files = await FileSystem.readDirectoryAsync(destDir);
      log(`Extracted contents: ${files.join(', ')}`, 'success');
    } catch (e: any) {
      setActiveLabel(null);
      log(`Error: ${e.message}`, 'error');
    }
  }, [log]);

  // ── Create zip ────────────────────────────────────────────────────
  const handleZip = useCallback(async () => {
    try {
      setProgress(0);
      setActiveLabel('Zipping...');

      // Create some files to zip
      const sourceDir = `${FileSystem.cacheDirectory}zip-source/`;
      const info = await FileSystem.getInfoAsync(sourceDir);
      if (info.exists) {
        await FileSystem.deleteAsync(sourceDir, { idempotent: true });
      }
      await FileSystem.makeDirectoryAsync(sourceDir, { intermediates: true });

      for (let i = 0; i < 10; i++) {
        await FileSystem.writeAsStringAsync(
          `${sourceDir}file${i}.txt`,
          `Content of file ${i}\n`.repeat(100),
        );
      }

      const destZip = `${FileSystem.cacheDirectory}created.zip`;

      log(`Source dir: ${sourceDir}`);
      log(`Output zip: ${destZip}`);

      const unzip = getUnzip();
      const task = unzip.zip(sourceDir, destZip);
      activeTask.current = task;

      log(`Task created: ${task.taskId}`);

      task.onProgress((p: ZipProgress) => {
        setProgress(p.progress);
        log(
          `${p.compressedFiles}/${p.totalFiles} files — ${(p.progress * 100).toFixed(0)}%`,
        );
      });

      const result = await task.await();
      activeTask.current = null;
      setProgress(1);
      setActiveLabel(null);

      log(
        `Done: ${result.compressedFiles} files in ${result.duration.toFixed(0)}ms — ${(result.totalBytes / 1024).toFixed(1)}KB`,
        'success',
      );
    } catch (e: any) {
      setActiveLabel(null);
      log(`Error: ${e.message}`, 'error');
    }
  }, [log]);

  // ── Extract with password ─────────────────────────────────────────
  const handlePasswordExtract = useCallback(async () => {
    try {
      setProgress(0);
      setActiveLabel('Password extract...');

      // First create a password-protected zip
      const sourceDir = `${FileSystem.cacheDirectory}pw-source/`;
      const info = await FileSystem.getInfoAsync(sourceDir);
      if (info.exists) {
        await FileSystem.deleteAsync(sourceDir, { idempotent: true });
      }
      await FileSystem.makeDirectoryAsync(sourceDir, { intermediates: true });

      await FileSystem.writeAsStringAsync(
        `${sourceDir}secret.txt`,
        'This is password-protected content!',
      );

      const pwZip = `${FileSystem.cacheDirectory}protected.zip`;
      const unzip = getUnzip();

      log('Creating password-protected zip...');
      const zipTask = unzip.zipWithPassword(sourceDir, pwZip, 'test123');
      const zipResult = await zipTask.await();
      log(`Created protected zip: ${zipResult.compressedFiles} files`, 'info');

      // Now extract it
      const extractDir = `${FileSystem.cacheDirectory}pw-extracted/`;
      const extractInfo = await FileSystem.getInfoAsync(extractDir);
      if (extractInfo.exists) {
        await FileSystem.deleteAsync(extractDir, { idempotent: true });
      }

      log('Extracting with password...');
      const task = unzip.extractWithPassword(pwZip, extractDir, 'test123');
      activeTask.current = task;

      task.onProgress((p: UnzipProgress) => {
        setProgress(p.progress);
      });

      const result = await task.await();
      activeTask.current = null;
      setProgress(1);
      setActiveLabel(null);

      log(
        `Extracted ${result.extractedFiles} files in ${result.duration.toFixed(0)}ms`,
        'success',
      );

      // Verify contents
      const content = await FileSystem.readAsStringAsync(
        `${extractDir}secret.txt`,
      );
      log(`Verified content: "${content.substring(0, 40)}..."`, 'success');
    } catch (e: any) {
      setActiveLabel(null);
      log(`Error: ${e.message}`, 'error');
    }
  }, [log]);

  return (
    <SafeAreaView style={styles.container}>
      <StatusBar style="light" />

      <Text style={styles.title}>react-native-nitro-unzip</Text>
      <Text style={styles.subtitle}>
        {Platform.OS} — Nitro Modules
      </Text>

      {/* Progress bar */}
      {progress !== null && (
        <View style={styles.progressContainer}>
          <View style={[styles.progressBar, { width: `${progress * 100}%` }]} />
          <Text style={styles.progressText}>
            {activeLabel ?? `${(progress * 100).toFixed(0)}%`}
          </Text>
        </View>
      )}

      {/* Action buttons */}
      <View style={styles.buttons}>
        <Pressable style={styles.button} onPress={handleExtract}>
          <Text style={styles.buttonText}>Extract ZIP</Text>
        </Pressable>
        <Pressable style={styles.button} onPress={handleZip}>
          <Text style={styles.buttonText}>Create ZIP</Text>
        </Pressable>
        <Pressable style={styles.button} onPress={handlePasswordExtract}>
          <Text style={styles.buttonText}>Password</Text>
        </Pressable>
        <Pressable
          style={[styles.button, styles.cancelButton]}
          onPress={cancel}
        >
          <Text style={styles.buttonText}>Cancel</Text>
        </Pressable>
      </View>

      <Pressable onPress={clearLogs}>
        <Text style={styles.clearText}>Clear logs</Text>
      </Pressable>

      {/* Logs */}
      <ScrollView style={styles.logs}>
        {logs.map((entry) => (
          <Text
            key={entry.id}
            style={[
              styles.logLine,
              entry.type === 'success' && styles.logSuccess,
              entry.type === 'error' && styles.logError,
            ]}
          >
            {entry.text}
          </Text>
        ))}
      </ScrollView>
    </SafeAreaView>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: '#1a1a2e',
    paddingTop: Platform.OS === 'android' ? 40 : 0,
  },
  title: {
    fontSize: 22,
    fontWeight: '700',
    color: '#e0e0e0',
    textAlign: 'center',
    marginTop: 16,
  },
  subtitle: {
    fontSize: 13,
    color: '#888',
    textAlign: 'center',
    marginBottom: 16,
  },
  progressContainer: {
    height: 28,
    backgroundColor: '#2a2a4a',
    marginHorizontal: 16,
    borderRadius: 6,
    overflow: 'hidden',
    justifyContent: 'center',
    marginBottom: 12,
  },
  progressBar: {
    ...StyleSheet.absoluteFillObject,
    backgroundColor: '#4a90d9',
    borderRadius: 6,
  },
  progressText: {
    color: '#fff',
    fontSize: 12,
    fontWeight: '600',
    textAlign: 'center',
  },
  buttons: {
    flexDirection: 'row',
    paddingHorizontal: 12,
    gap: 8,
    marginBottom: 8,
  },
  button: {
    flex: 1,
    backgroundColor: '#4a90d9',
    paddingVertical: 10,
    borderRadius: 8,
    alignItems: 'center',
  },
  cancelButton: {
    backgroundColor: '#d94a4a',
  },
  buttonText: {
    color: '#fff',
    fontWeight: '600',
    fontSize: 13,
  },
  clearText: {
    color: '#666',
    textAlign: 'center',
    fontSize: 12,
    marginBottom: 8,
  },
  logs: {
    flex: 1,
    backgroundColor: '#0d0d1a',
    marginHorizontal: 12,
    borderRadius: 8,
    padding: 10,
  },
  logLine: {
    color: '#aaa',
    fontSize: 11,
    fontFamily: Platform.OS === 'ios' ? 'Menlo' : 'monospace',
    lineHeight: 18,
  },
  logSuccess: {
    color: '#4ade80',
  },
  logError: {
    color: '#f87171',
  },
});
