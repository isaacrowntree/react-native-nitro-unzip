import { StatusBar } from 'expo-status-bar';
import { StyleSheet, Text, View } from 'react-native';
import { getUnzip } from 'react-native-nitro-unzip';

export default function App() {
  let status = 'not-loaded';
  try {
    const unzip = getUnzip();
    status = typeof unzip?.extract === 'function' ? 'ok' : 'missing-api';
  } catch (e: any) {
    status = `error: ${e?.message ?? String(e)}`;
  }
  return (
    <View style={styles.container}>
      <Text>NitroUnzip: {status}</Text>
      <StatusBar style="auto" />
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: '#fff',
    alignItems: 'center',
    justifyContent: 'center',
  },
});
