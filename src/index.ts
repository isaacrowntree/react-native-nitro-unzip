import { NitroModules } from "react-native-nitro-modules";
import type { Unzip } from "./specs/Unzip.nitro";

export type {
  UnzipProgress,
  UnzipResult,
  UnzipTask,
  ZipProgress,
  ZipResult,
  ZipTask,
  Unzip,
} from "./specs/Unzip.nitro";

/**
 * Create an `Unzip` instance. Each instance is a factory for
 * extraction and compression tasks.
 *
 * @example
 * ```typescript
 * import { getUnzip } from 'react-native-nitro-unzip'
 *
 * const unzip = getUnzip()
 *
 * // Extract
 * const task = unzip.extract('/path/to/archive.zip', '/output')
 * task.onProgress((p) => console.log(`${(p.progress * 100).toFixed(0)}%`))
 * const result = await task.await()
 *
 * // Zip
 * const zipTask = unzip.zip('/path/to/folder', '/output.zip')
 * const zipResult = await zipTask.await()
 * ```
 */
export function getUnzip(): Unzip {
  return NitroModules.createHybridObject<Unzip>("Unzip");
}
