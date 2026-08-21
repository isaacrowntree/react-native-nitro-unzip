import type { HybridObject } from 'react-native-nitro-modules';

// ─── Extraction types ────────────────────────────────────────────────

/**
 * Progress information for an active extraction.
 */
export interface UnzipProgress {
  /** Number of files extracted so far */
  extractedFiles: number;
  /** Total number of files in the archive */
  totalFiles: number;
  /** Extraction progress from 0.0 to 1.0 */
  progress: number;
  /** Current extraction speed in files per second */
  speed: number;
  /** Number of bytes processed so far */
  processedBytes: number;
}

/**
 * Result returned when an extraction completes successfully.
 */
export interface UnzipResult {
  /** Whether extraction completed successfully */
  success: boolean;
  /** Total number of files extracted */
  extractedFiles: number;
  /** Total number of files in the archive */
  totalFiles: number;
  /** Total extraction duration in milliseconds */
  duration: number;
  /** Average extraction speed in files per second */
  averageSpeed: number;
  /** Total bytes extracted */
  totalBytes: number;
}

/**
 * A single extraction operation. Each call to `Unzip.extract()` returns
 * an `UnzipTask` instance that can be observed and cancelled independently.
 *
 * This is a proper HybridObject — a native instance you interact with
 * directly, not an opaque task ID.
 */
export interface UnzipTask extends HybridObject<{
  ios: 'swift';
  android: 'kotlin';
}> {
  /** Unique identifier for this extraction task */
  readonly taskId: string;

  /**
   * Register a callback to receive progress updates.
   * Progress is throttled to ~1 update per second to avoid bridge overhead.
   * The first file and final file always trigger a callback.
   */
  onProgress(callback: (progress: UnzipProgress) => void): void;

  /** Cancel this extraction. Safe to call multiple times. */
  cancel(): void;

  /**
   * Await the extraction result. Resolves when extraction completes,
   * rejects if cancelled or an error occurs.
   */
  await(): Promise<UnzipResult>;
}

// ─── Compression types ───────────────────────────────────────────────

/**
 * Progress information for an active zip creation.
 */
export interface ZipProgress {
  /** Number of files compressed so far */
  compressedFiles: number;
  /** Total number of files to compress */
  totalFiles: number;
  /** Compression progress from 0.0 to 1.0 */
  progress: number;
  /** Current compression speed in files per second */
  speed: number;
}

/**
 * Result returned when zip creation completes successfully.
 */
export interface ZipResult {
  /** Whether compression completed successfully */
  success: boolean;
  /** Total number of files compressed */
  compressedFiles: number;
  /** Total number of files to compress */
  totalFiles: number;
  /** Total compression duration in milliseconds */
  duration: number;
  /** Average compression speed in files per second */
  averageSpeed: number;
  /** Total bytes written to the zip file */
  totalBytes: number;
}

/**
 * A single zip creation operation. Each call to `Unzip.zip()` returns
 * a `ZipTask` instance that can be observed and cancelled independently.
 */
export interface ZipTask extends HybridObject<{
  ios: 'swift';
  android: 'kotlin';
}> {
  /** Unique identifier for this zip task */
  readonly taskId: string;

  /**
   * Register a callback to receive progress updates.
   * Progress is throttled to ~1 update per second.
   */
  onProgress(callback: (progress: ZipProgress) => void): void;

  /** Cancel this zip creation. Safe to call multiple times. */
  cancel(): void;

  /**
   * Await the zip result. Resolves when zip creation completes,
   * rejects if cancelled or an error occurs.
   */
  await(): Promise<ZipResult>;
}

// ─── Factory ─────────────────────────────────────────────────────────

/**
 * Factory for creating extraction and compression tasks.
 *
 * @example
 * ```typescript
 * import { getUnzip } from 'react-native-nitro-unzip'
 *
 * const unzip = getUnzip()
 *
 * // Extract
 * const task = unzip.extract('/path/to/archive.zip', '/path/to/output')
 * task.onProgress((p) => console.log(`${(p.progress * 100).toFixed(0)}%`))
 * const result = await task.await()
 *
 * // Extract with password
 * const pwTask = unzip.extractWithPassword('/path/to/encrypted.zip', '/output', 'secret')
 * const pwResult = await pwTask.await()
 *
 * // Create zip
 * const zipTask = unzip.zip('/path/to/folder', '/path/to/output.zip')
 * const zipResult = await zipTask.await()
 * ```
 */
export interface Unzip extends HybridObject<{
  ios: 'swift';
  android: 'kotlin';
}> {
  /**
   * Start extracting a ZIP archive to the given destination directory.
   * Returns an `UnzipTask` instance for progress tracking and cancellation.
   *
   * @param zipPath - Absolute path to the ZIP file (file:// URIs accepted)
   * @param destinationPath - Absolute path to extract into (created if missing)
   */
  extract(zipPath: string, destinationPath: string): UnzipTask;

  /**
   * Extract a password-protected ZIP archive.
   *
   * @param zipPath - Absolute path to the ZIP file
   * @param destinationPath - Absolute path to extract into
   * @param password - Password for the encrypted archive
   */
  extractWithPassword(
    zipPath: string,
    destinationPath: string,
    password: string,
  ): UnzipTask;

  /**
   * Create a ZIP archive from a directory.
   *
   * @param sourcePath - Absolute path to the directory to compress
   * @param destinationZipPath - Absolute path for the output ZIP file
   */
  zip(sourcePath: string, destinationZipPath: string): ZipTask;

  /**
   * Create a password-protected ZIP archive from a directory.
   * Uses AES-256 encryption on both Android (via zip4j) and iOS (via
   * SSZipArchive's AES variant). 0.3 used weak PKWARE-traditional
   * encryption on iOS; 0.5.0 brings cross-platform AES-256 parity.
   *
   * @param sourcePath - Absolute path to the directory to compress
   * @param destinationZipPath - Absolute path for the output ZIP file
   * @param password - Password to protect the archive
   */
  zipWithPassword(
    sourcePath: string,
    destinationZipPath: string,
    password: string,
  ): ZipTask;
}
