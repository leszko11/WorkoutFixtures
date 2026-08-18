import CZlib
import Foundation

/// Failures raised while compressing or decompressing gzip data.
public enum GzipCodingError: Error, Equatable, Sendable, LocalizedError {
  /// The data does not decompress as a gzip (or zlib) stream.
  case corruptedData
  /// The gzip stream ended before the compressed payload was complete.
  case truncatedData
  /// zlib reported an unexpected failure with the given status code.
  case underlyingZlibError(code: Int32)

  public var errorDescription: String? {
    switch self {
    case .corruptedData:
      "The data is not a valid gzip stream."
    case .truncatedData:
      "The gzip stream ended before the compressed payload was complete."
    case .underlyingZlibError(let code):
      "zlib failed with status code \(code)."
    }
  }
}

/// Gzip transport encoding for fixture JSON.
///
/// Fixture and archive files are often shipped compressed (`.json.gz`);
/// this codec lets every reader accept them transparently. Compression is
/// a transport concern only — the JSON wire format and its schema version
/// are unchanged by gzipping.
public enum GzipCodec {
  private static let gzipMagic: [UInt8] = [0x1f, 0x8b]
  private static let chunkSize = 1 << 16

  /// Whether `data` starts with the gzip magic number.
  public static func isGzipped(_ data: Data) -> Bool {
    data.count >= gzipMagic.count && data.prefix(gzipMagic.count).elementsEqual(gzipMagic)
  }

  /// Decompresses a gzip (or zlib) stream.
  /// - Throws: ``GzipCodingError`` when the stream is corrupt or truncated.
  public static func decompress(_ data: Data) throws -> Data {
    guard !data.isEmpty else { throw GzipCodingError.corruptedData }
    var stream = z_stream()
    // windowBits 15 + 32 enables automatic gzip/zlib header detection.
    let initStatus = inflateInit2_(
      &stream, 15 + 32, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
    guard initStatus == Z_OK else {
      throw GzipCodingError.underlyingZlibError(code: initStatus)
    }
    defer { inflateEnd(&stream) }

    var output = Data()
    var buffer = [UInt8](repeating: 0, count: chunkSize)
    var status: Int32 = Z_OK
    try data.withUnsafeBytes { (input: UnsafeRawBufferPointer) in
      guard let inputBase = input.bindMemory(to: UInt8.self).baseAddress else {
        throw GzipCodingError.corruptedData
      }
      stream.next_in = UnsafeMutablePointer(mutating: inputBase)
      stream.avail_in = uInt(data.count)
      repeat {
        var produced = 0
        try buffer.withUnsafeMutableBufferPointer { out in
          stream.next_out = out.baseAddress
          stream.avail_out = uInt(chunkSize)
          status = inflate(&stream, Z_NO_FLUSH)
          switch status {
          case Z_OK, Z_STREAM_END, Z_BUF_ERROR:
            produced = chunkSize - Int(stream.avail_out)
          case Z_DATA_ERROR, Z_NEED_DICT:
            throw GzipCodingError.corruptedData
          default:
            throw GzipCodingError.underlyingZlibError(code: status)
          }
        }
        output.append(contentsOf: buffer.prefix(produced))
        if status == Z_BUF_ERROR, stream.avail_in == 0 {
          throw GzipCodingError.truncatedData
        }
      } while status != Z_STREAM_END
    }
    guard status == Z_STREAM_END else { throw GzipCodingError.truncatedData }
    return output
  }

  /// Compresses `data` into a gzip stream (default zlib compression level).
  public static func compress(_ data: Data) throws -> Data {
    var stream = z_stream()
    // windowBits 15 + 16 selects gzip framing for the output stream.
    let initStatus = deflateInit2_(
      &stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, 15 + 16, 8, Z_DEFAULT_STRATEGY,
      ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
    guard initStatus == Z_OK else {
      throw GzipCodingError.underlyingZlibError(code: initStatus)
    }
    defer { deflateEnd(&stream) }

    var output = Data()
    var buffer = [UInt8](repeating: 0, count: chunkSize)
    var status: Int32 = Z_OK
    try data.withUnsafeBytes { (input: UnsafeRawBufferPointer) in
      stream.next_in = input.bindMemory(to: UInt8.self).baseAddress.map {
        UnsafeMutablePointer(mutating: $0)
      }
      stream.avail_in = uInt(data.count)
      repeat {
        var produced = 0
        try buffer.withUnsafeMutableBufferPointer { out in
          stream.next_out = out.baseAddress
          stream.avail_out = uInt(chunkSize)
          status = deflate(&stream, Z_FINISH)
          guard status == Z_OK || status == Z_STREAM_END || status == Z_BUF_ERROR else {
            throw GzipCodingError.underlyingZlibError(code: status)
          }
          produced = chunkSize - Int(stream.avail_out)
        }
        output.append(contentsOf: buffer.prefix(produced))
      } while status != Z_STREAM_END
    }
    return output
  }
}
