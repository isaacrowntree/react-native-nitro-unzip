import Foundation

/// Reads entry names straight out of a ZIP central directory.
///
/// The password-protected extract path needs the full entry list *before* it
/// writes anything, so it can run the Zip Slip and duplicate-name checks. It
/// previously got that list from ZIPFoundation, which yields nothing for
/// WinZip AES archives (compression method 99) — so on an encrypted archive
/// the validation loop iterated an empty array and every check was skipped.
///
/// The central directory records names independently of how entry data is
/// compressed or encrypted, so parsing it directly works for every archive we
/// accept. Deliberately dependency-free: it is pure Foundation, which is what
/// lets it be unit tested without the CocoaPods toolchain.
enum ZipCentralDirectory {
  enum ReadError: Error {
    case notAZipArchive
    case malformed(String)
  }

  private static let endOfCentralDirectorySignature: UInt32 = 0x0605_4b50
  private static let zip64LocatorSignature: UInt32 = 0x0706_4b50
  private static let zip64EndSignature: UInt32 = 0x0606_4b50
  private static let centralFileHeaderSignature: UInt32 = 0x0201_4b50

  /// Every entry name in the archive, in central-directory order.
  ///
  /// Directory entries keep their trailing "/" — callers need to see them,
  /// both to validate their paths and to tell files from directories.
  static func entryNames(at url: URL) throws -> [String] {
    let data = try Data(contentsOf: url, options: .mappedIfSafe)
    let eocd = try findEndOfCentralDirectory(in: data)

    var entryCount = Int(data.u16(at: eocd + 10))
    var directoryOffset = Int(data.u32(at: eocd + 16))

    // ZIP64: the 32-bit fields saturate and the real values live in the ZIP64
    // end record, found via a locator immediately before the EOCD.
    if entryCount == 0xFFFF || directoryOffset == 0xFFFF_FFFF {
      let locator = eocd - 20
      guard locator >= 0, data.u32(at: locator) == zip64LocatorSignature else {
        throw ReadError.malformed("ZIP64 fields present but no ZIP64 locator")
      }
      let zip64End = Int(data.u64(at: locator + 8))
      guard zip64End >= 0, zip64End + 56 <= data.count,
        data.u32(at: zip64End) == zip64EndSignature
      else {
        throw ReadError.malformed("ZIP64 end of central directory not found")
      }
      entryCount = Int(data.u64(at: zip64End + 32))
      directoryOffset = Int(data.u64(at: zip64End + 48))
    }

    guard directoryOffset >= 0, directoryOffset <= data.count else {
      throw ReadError.malformed("central directory offset outside archive")
    }

    var names: [String] = []
    names.reserveCapacity(entryCount)
    var cursor = directoryOffset

    for _ in 0..<entryCount {
      // A fixed central file header is 46 bytes before the variable fields.
      guard cursor + 46 <= data.count else {
        throw ReadError.malformed("central directory truncated")
      }
      guard data.u32(at: cursor) == centralFileHeaderSignature else {
        throw ReadError.malformed("bad central file header signature")
      }

      let nameLength = Int(data.u16(at: cursor + 28))
      let extraLength = Int(data.u16(at: cursor + 30))
      let commentLength = Int(data.u16(at: cursor + 32))
      let nameStart = cursor + 46
      guard nameStart + nameLength <= data.count else {
        throw ReadError.malformed("entry name truncated")
      }

      let nameBytes = data.subdata(in: nameStart..<(nameStart + nameLength))
      // Bit 11 of the general purpose flags marks UTF-8. Archives in the wild
      // frequently lie or omit it, so fall back rather than dropping an entry:
      // an entry we cannot name is an entry we cannot path-check.
      let isUTF8 = (data.u16(at: cursor + 8) & 0x0800) != 0
      guard
        let name = String(data: nameBytes, encoding: isUTF8 ? .utf8 : .utf8)
          ?? String(data: nameBytes, encoding: .isoLatin1)
      else {
        throw ReadError.malformed("entry name is not decodable")
      }
      names.append(name)

      cursor = nameStart + nameLength + extraLength + commentLength
    }

    return names
  }

  /// Scans backwards for the end-of-central-directory signature. It sits at
  /// the very end unless the archive carries a comment, which can be up to
  /// 65535 bytes.
  private static func findEndOfCentralDirectory(in data: Data) throws -> Int {
    let minimumSize = 22
    guard data.count >= minimumSize else { throw ReadError.notAZipArchive }

    let earliest = max(0, data.count - minimumSize - 0xFFFF)
    var index = data.count - minimumSize
    while index >= earliest {
      if data.u32(at: index) == endOfCentralDirectorySignature {
        return index
      }
      index -= 1
    }
    throw ReadError.notAZipArchive
  }
}

private extension Data {
  /// ZIP integers are little-endian and unaligned, so read them byte-wise
  /// rather than binding memory to a wider type.
  func u16(at offset: Int) -> UInt16 {
    let base = startIndex + offset
    return UInt16(self[base]) | (UInt16(self[base + 1]) << 8)
  }

  func u32(at offset: Int) -> UInt32 {
    let base = startIndex + offset
    guard base + 3 < endIndex else { return 0 }
    return UInt32(self[base]) | (UInt32(self[base + 1]) << 8)
      | (UInt32(self[base + 2]) << 16) | (UInt32(self[base + 3]) << 24)
  }

  func u64(at offset: Int) -> UInt64 {
    UInt64(u32(at: offset)) | (UInt64(u32(at: offset + 4)) << 32)
  }
}
