import AVFoundation
import CryptoKit
import Foundation
import Security
import UniformTypeIdentifiers

/// Shared `AUNDL01` chunked AES-256-GCM binary format matching `AlUmmahNowCore` (`crates/aun-downloads`):
/// - Header: `MAGIC("AUNDL01\0")` (8 B) + base nonce (8 B) + `u16 BE videoIdLen` + `videoId`
///   + `u16 BE licenseIdLen` + `licenseId`
/// - Fixed 64 KiB plaintext chunks + 16 B GCM tag (`65552` B stride), `is_final` flag in AAD.
/// - Opening `AunDl01RandomAccessReader` authenticates the final chunk immediately so truncated or
///   cross-license files fail on open.
public enum AunDl01Format {
    public static let magic = Data([0x41, 0x55, 0x4E, 0x44, 0x4C, 0x30, 0x31, 0x00])
    public static let chunkSize = 64 * 1024
    public static let tagLen = 16
    public static let chunkStride = chunkSize + tagLen
    public static let baseNonceLen = 8
    private static let maxIdLen = 512

    static func validateBinding(videoId: String, licenseId: String) throws {
        let vidCount = videoId.utf8.count
        let licCount = licenseId.utf8.count
        guard vidCount > 0, vidCount <= maxIdLen, licCount > 0, licCount <= maxIdLen else {
            throw OfflineDownloadError.invalidBinding
        }
    }

    static func chunkNonce(prefix: Data, index: UInt32) throws -> AES.GCM.Nonce {
        var raw = Data(capacity: 12)
        raw.append(prefix)
        var be = index.bigEndian
        withUnsafeBytes(of: &be) { raw.append(contentsOf: $0) }
        return try AES.GCM.Nonce(data: raw)
    }

    static func buildAAD(videoId: String, licenseId: String, index: UInt32, isFinal: Bool) -> Data {
        let vid = Data(videoId.utf8)
        let lic = Data(licenseId.utf8)
        var aad = Data(capacity: magic.count + 2 + vid.count + 2 + lic.count + 4 + 1)
        aad.append(magic)
        var vidLen = UInt16(vid.count).bigEndian
        withUnsafeBytes(of: &vidLen) { aad.append(contentsOf: $0) }
        aad.append(vid)
        var licLen = UInt16(lic.count).bigEndian
        withUnsafeBytes(of: &licLen) { aad.append(contentsOf: $0) }
        aad.append(lic)
        var idxBE = index.bigEndian
        withUnsafeBytes(of: &idxBE) { aad.append(contentsOf: $0) }
        aad.append(isFinal ? 1 : 0)
        return aad
    }
}

/// Streaming single-pass `AUNDL01` encryptor holding at most ~64 KiB of plaintext in RAM.
public final class AunDl01StreamWriter {
    private let key: SymmetricKey
    private let prefix: Data
    private let videoId: String
    private let licenseId: String
    private let tmpURL: URL
    private let destURL: URL
    private var handle: FileHandle?
    private var pending = Data()
    private var chunkIndex: UInt32 = 0
    private var finished = false

    public init(key: SymmetricKey, destination: URL, videoId: String, licenseId: String) throws {
        try AunDl01Format.validateBinding(videoId: videoId, licenseId: licenseId)
        self.key = key
        self.videoId = videoId
        self.licenseId = licenseId
        self.destURL = destination
        self.tmpURL = destination.appendingPathExtension("aun.tmp")

        var nonceBytes = [UInt8](repeating: 0, count: AunDl01Format.baseNonceLen)
        let rngStatus = SecRandomCopyBytes(kSecRandomDefault, nonceBytes.count, &nonceBytes)
        guard rngStatus == errSecSuccess else { throw OfflineDownloadError.invalidKey }
        self.prefix = Data(nonceBytes)

        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: tmpURL.path, contents: nil)
        let fh = try FileHandle(forWritingTo: tmpURL)
        self.handle = fh

        let vid = Data(videoId.utf8)
        let lic = Data(licenseId.utf8)
        var hdr = Data(capacity: 16 + 2 + vid.count + 2 + lic.count)
        hdr.append(AunDl01Format.magic)
        hdr.append(prefix)
        var vidLen = UInt16(vid.count).bigEndian
        withUnsafeBytes(of: &vidLen) { hdr.append(contentsOf: $0) }
        hdr.append(vid)
        var licLen = UInt16(lic.count).bigEndian
        withUnsafeBytes(of: &licLen) { hdr.append(contentsOf: $0) }
        hdr.append(lic)
        try fh.write(contentsOf: hdr)
    }

    deinit {
        if !finished {
            try? handle?.close()
            try? FileManager.default.removeItem(at: tmpURL)
        }
    }

    public func write(_ chunk: Data) throws {
        guard !finished, let fh = handle else { throw OfflineDownloadError.truncated }
        pending.append(chunk)
        while pending.count > AunDl01Format.chunkSize {
            let slice = pending.prefix(AunDl01Format.chunkSize)
            pending.removeFirst(AunDl01Format.chunkSize)
            let nonce = try AunDl01Format.chunkNonce(prefix: prefix, index: chunkIndex)
            let aad = AunDl01Format.buildAAD(
                videoId: videoId,
                licenseId: licenseId,
                index: chunkIndex,
                isFinal: false
            )
            let sealed = try AES.GCM.seal(slice, using: key, nonce: nonce, authenticating: aad)
            try fh.write(contentsOf: sealed.ciphertext)
            try fh.write(contentsOf: sealed.tag)
            chunkIndex += 1
        }
    }

    @discardableResult
    public func finish() throws -> Int64 {
        guard !finished, let fh = handle else { throw OfflineDownloadError.truncated }
        let nonce = try AunDl01Format.chunkNonce(prefix: prefix, index: chunkIndex)
        let aad = AunDl01Format.buildAAD(
            videoId: videoId,
            licenseId: licenseId,
            index: chunkIndex,
            isFinal: true
        )
        let sealed = try AES.GCM.seal(pending, using: key, nonce: nonce, authenticating: aad)
        try fh.write(contentsOf: sealed.ciphertext)
        try fh.write(contentsOf: sealed.tag)
        try fh.synchronize()
        try fh.close()
        handle = nil
        pending.removeAll(keepingCapacity: false)
        if FileManager.default.fileExists(atPath: destURL.path) {
            try FileManager.default.removeItem(at: destURL)
        }
        try FileManager.default.moveItem(at: tmpURL, to: destURL)
        finished = true
        let attrs = try FileManager.default.attributesOfItem(atPath: destURL.path)
        return (attrs[.size] as? NSNumber)?.int64Value ?? 0
    }

    public static func encryptFile(
        key: SymmetricKey,
        source: URL,
        destination: URL,
        videoId: String,
        licenseId: String
    ) throws -> Int64 {
        let reader = try FileHandle(forReadingFrom: source)
        defer { try? reader.close() }
        let writer = try AunDl01StreamWriter(
            key: key,
            destination: destination,
            videoId: videoId,
            licenseId: licenseId
        )
        while let data = try reader.read(upToCount: AunDl01Format.chunkSize), !data.isEmpty {
            try writer.write(data)
        }
        return try writer.finish()
    }
}

/// O(1) random-access chunked AES-256-GCM decrypt-on-read reader for `AUNDL01` files.
/// Never loads the whole file into memory and never writes plaintext to disk.
public final class AunDl01RandomAccessReader: @unchecked Sendable {
    private let key: SymmetricKey
    private let handle: FileHandle
    private let prefix: Data
    public let videoId: String
    public let licenseId: String
    private let dataOffset: UInt64
    public let plainLen: UInt64
    private let numChunks: UInt32
    private let lock = NSLock()
    private var cachedIndex: UInt32?
    private var cachedChunk = Data()

    public init(
        key: SymmetricKey,
        url: URL,
        expectedVideoId: String,
        expectedLicenseId: String
    ) throws {
        try AunDl01Format.validateBinding(videoId: expectedVideoId, licenseId: expectedLicenseId)
        let fh = try FileHandle(forReadingFrom: url)
        do {
            let fileLen = try fh.seekToEnd()
            try fh.seek(toOffset: 0)
            guard fileLen >= 16, let fixed = try fh.read(upToCount: 16), fixed.count == 16 else {
                throw OfflineDownloadError.invalidHeader
            }
            guard fixed.prefix(8) == AunDl01Format.magic else {
                throw OfflineDownloadError.invalidHeader
            }
            let prefix = Data(fixed.dropFirst(8))

            func readU16String() throws -> String {
                guard let lenData = try fh.read(upToCount: 2), lenData.count == 2 else {
                    throw OfflineDownloadError.truncated
                }
                let count = Int(UInt16(lenData[0]) << 8 | UInt16(lenData[1]))
                guard count > 0, count <= 512,
                    let bytes = try fh.read(upToCount: count), bytes.count == count,
                    let str = String(data: bytes, encoding: .utf8)
                else {
                    throw OfflineDownloadError.invalidHeader
                }
                return str
            }

            let headerVideoId = try readU16String()
            let headerLicenseId = try readU16String()
            guard headerVideoId == expectedVideoId, headerLicenseId == expectedLicenseId else {
                throw OfflineDownloadError.invalidBinding
            }
            let dataOffset = try fh.offset()
            guard fileLen >= dataOffset + UInt64(AunDl01Format.tagLen) else {
                throw OfflineDownloadError.truncated
            }
            let payloadLen = fileLen - dataOffset
            let stride = UInt64(AunDl01Format.chunkStride)
            let numChunks64 = ((payloadLen - 1) / stride) + 1
            let lastFrameLen = payloadLen - (numChunks64 - 1) * stride
            guard lastFrameLen >= UInt64(AunDl01Format.tagLen), lastFrameLen <= stride else {
                throw OfflineDownloadError.truncated
            }
            if numChunks64 > 1 && lastFrameLen == UInt64(AunDl01Format.tagLen) {
                throw OfflineDownloadError.truncated
            }
            let plainLen =
                (numChunks64 - 1) * UInt64(AunDl01Format.chunkSize)
                + (lastFrameLen - UInt64(AunDl01Format.tagLen))

            self.key = key
            self.handle = fh
            self.prefix = prefix
            self.videoId = headerVideoId
            self.licenseId = headerLicenseId
            self.dataOffset = dataOffset
            self.plainLen = plainLen
            self.numChunks = UInt32(numChunks64)

            // Immediately authenticate the final chunk so truncation/wrong key fails on open.
            _ = try loadChunkLocked(self.numChunks - 1)
        } catch {
            try? fh.close()
            throw error
        }
    }

    deinit {
        try? handle.close()
    }

    public func readRange(offset: UInt64, length: Int) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        guard offset < plainLen, length > 0 else { return Data() }
        let toRead = Int(min(UInt64(length), plainLen - offset))
        var out = Data(capacity: toRead)
        var pos = offset
        var remaining = toRead
        while remaining > 0 {
            let idx = UInt32(pos / UInt64(AunDl01Format.chunkSize))
            let inChunk = Int(pos % UInt64(AunDl01Format.chunkSize))
            let chunk = try loadChunkLocked(idx)
            let take = min(chunk.count - inChunk, remaining)
            out.append(chunk[inChunk..<(inChunk + take)])
            pos += UInt64(take)
            remaining -= take
        }
        return out
    }

    private func loadChunkLocked(_ index: UInt32) throws -> Data {
        if cachedIndex == index { return cachedChunk }
        guard index < numChunks else { throw OfflineDownloadError.truncated }
        let isFinal = index == numChunks - 1
        let chunkPlainLen: Int
        if isFinal {
            chunkPlainLen = Int(plainLen - UInt64(index) * UInt64(AunDl01Format.chunkSize))
        } else {
            chunkPlainLen = AunDl01Format.chunkSize
        }
        let frameLen = chunkPlainLen + AunDl01Format.tagLen
        let fileOffset = dataOffset + UInt64(index) * UInt64(AunDl01Format.chunkStride)
        try handle.seek(toOffset: fileOffset)
        guard let frame = try handle.read(upToCount: frameLen), frame.count == frameLen else {
            throw OfflineDownloadError.truncated
        }
        let ciphertext = frame.prefix(chunkPlainLen)
        let tag = frame.suffix(AunDl01Format.tagLen)
        let nonce = try AunDl01Format.chunkNonce(prefix: prefix, index: index)
        let aad = AunDl01Format.buildAAD(
            videoId: videoId,
            licenseId: licenseId,
            index: index,
            isFinal: isFinal
        )
        let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
        let plain = try AES.GCM.open(box, using: key, authenticating: aad)
        cachedChunk = plain
        cachedIndex = index
        return cachedChunk
    }
}

/// `AVAssetResourceLoaderDelegate` serving `aun-offline://<videoId>` via 64 KiB on-demand chunk
/// decryption from `AunDl01RandomAccessReader` — zero plaintext temp files, zero whole-file RAM.
public final class AunOfflineAssetResourceLoaderDelegate: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    public static let scheme = "aun-offline"

    private let reader: AunDl01RandomAccessReader
    private let contentType: String

    public init(reader: AunDl01RandomAccessReader, quality: OfflineDownloadQuality) {
        self.reader = reader
        self.contentType = quality == .audio ? UTType.mpeg4Audio.identifier : UTType.mpeg4Movie.identifier
    }

    public static func assetURL(for videoId: String) -> URL {
        URL(string: "\(scheme)://\(videoId)")!
    }

    public func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        if let info = loadingRequest.contentInformationRequest {
            info.contentType = contentType
            info.contentLength = Int64(reader.plainLen)
            info.isByteRangeAccessSupported = true
        }
        if let dataReq = loadingRequest.dataRequest {
            let start = UInt64(max(0, dataReq.currentOffset))
            let want =
                dataReq.requestsAllDataToEndOfResource
                ? Int(reader.plainLen - min(start, reader.plainLen))
                : dataReq.requestedLength
            var pos = start
            var remaining = want
            do {
                while remaining > 0 {
                    let step = min(remaining, AunDl01Format.chunkSize)
                    let chunk = try reader.readRange(offset: pos, length: step)
                    if chunk.isEmpty { break }
                    dataReq.respond(with: chunk)
                    pos += UInt64(chunk.count)
                    remaining -= chunk.count
                }
            } catch {
                loadingRequest.finishLoading(with: error)
                return true
            }
        }
        loadingRequest.finishLoading()
        return true
    }
}
