package com.margelo.nitro.unzip

import net.lingala.zip4j.ZipFile
import net.lingala.zip4j.model.ZipParameters
import net.lingala.zip4j.model.enums.AesKeyStrength
import net.lingala.zip4j.model.enums.EncryptionMethod
import java.io.BufferedOutputStream
import java.io.File
import java.io.FileOutputStream
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream

/**
 * Programmatic ZIP fixture builder for JVM unit tests. Lets tests construct
 * exactly the archive they need (nested paths, malicious Zip Slip payloads,
 * password-protected variants) without checking binary fixtures into the
 * repo. zip4j is reused for password support so the test fixture matches
 * the production decrypt path.
 */
internal object ZipFixtures {

  /**
   * Write a plain ZIP at [file] containing the supplied [entries]. Each
   * entry is `path -> bytes`. A trailing `/` on the path marks a directory
   * entry; otherwise the path is treated as a file.
   */
  fun writeZip(file: File, entries: List<Pair<String, ByteArray>>) {
    ZipOutputStream(BufferedOutputStream(FileOutputStream(file))).use { zos ->
      for ((path, content) in entries) {
        zos.putNextEntry(ZipEntry(path))
        if (!path.endsWith("/")) {
          zos.write(content)
        }
        zos.closeEntry()
      }
    }
  }

  /**
   * Generate a ZIP with [count] flat file entries named `file_000.bin`,
   * `file_001.bin`, ... — useful for throttling/cancellation tests where
   * the contents don't matter, only the entry count and roughly-uniform
   * extraction work per entry.
   */
  fun writeFlatZip(file: File, count: Int, bytesPerEntry: Int = 64): File {
    val content = ByteArray(bytesPerEntry) { (it % 256).toByte() }
    val entries = (0 until count).map { i ->
      "file_${i.toString().padStart(3, '0')}.bin" to content
    }
    writeZip(file, entries)
    return file
  }

  /**
   * Generate a ZIP with [count] files spread across a deeply-nested
   * directory structure — the realistic workload for things like tile
   * sets, asset bundles, and downloaded SDK archives. Each file's path
   * is derived from its index in base-8 so the tree has both depth and
   * branching.
   *
   * For `count = 1000`, you get ~512 unique directories across 3 levels
   * of nesting with ~2 files per leaf — enough to exercise the
   * directory dedup set, the ancestry-symlink-check cache, and the
   * mkdir-batching paths in production.
   */
  fun writeNestedZip(file: File, count: Int, bytesPerEntry: Int = 64): File {
    val content = ByteArray(bytesPerEntry) { (it % 256).toByte() }
    val entries = (0 until count).map { i ->
      val d0 = (i / 64) % 8
      val d1 = (i / 8) % 8
      val d2 = i % 8
      "tier_$d0/sub_$d1/leaf_$d2/file_${i.toString().padStart(4, '0')}.bin" to content
    }
    writeZip(file, entries)
    return file
  }

  /**
   * Write a password-protected ZIP (AES-256) via zip4j. The fixture matches
   * what zip4j's decrypt path expects in production.
   */
  fun writeProtectedZip(
    file: File,
    password: String,
    entries: List<Pair<String, ByteArray>>
  ) {
    if (file.exists()) file.delete()
    ZipFile(file, password.toCharArray()).use { zip ->
      val params = ZipParameters().apply {
        isEncryptFiles = true
        encryptionMethod = EncryptionMethod.AES
        aesKeyStrength = AesKeyStrength.KEY_STRENGTH_256
      }
      for ((path, content) in entries) {
        params.fileNameInZip = path
        zip.addStream(content.inputStream(), params)
      }
    }
  }
}
