import Compression
import CryptoKit
import Foundation

/// Encodes and decodes guide cache files. Every input is untrusted: framing, lengths, the payload
/// digest and each record are checked, and decompression stops at a hard size limit.
///
/// Version 2 (frozen; see `docs/livetv/epg-cache-format.md`). Integers are big-endian.
///
/// | Offset | Size | Field |
/// |---|---|---|
/// | 0 | 4 | Magic `KEPG` |
/// | 4 | 1 | Version, `2` |
/// | 5 | 3 | Reserved, zero |
/// | 8 | 4 | Header length, `156` |
/// | 12 | 16 | Provider ID (UUID bytes) |
/// | 28 | 16 | Content ID, random per write |
/// | 44 | 32 | Source fingerprint (opaque) |
/// | 76 | 8 | `fetchedAt`, IEEE 754 double, seconds since 1970 |
/// | 84 | 8 | Coverage start, whole seconds since 1970; `0` when there are no programmes |
/// | 92 | 8 | Coverage end, likewise |
/// | 100 | 4 | Programme count |
/// | 104 | 4 | Channel count |
/// | 108 | 8 | Compressed payload length; the file ends exactly after the payload |
/// | 116 | 8 | Decompressed payload length |
/// | 124 | 32 | SHA-256 of the compressed payload bytes only |
/// | 156 | n | Payload: one LZFSE stream of the JSON record, with no trailing bytes |
///
/// The payload's LZFSE block headers must end exactly at the end of the file and declare exactly the
/// decompressed length; the stream decoder alone cannot detect trailing data.
///
/// The digest detects corruption; it does not authenticate. Version 1 is `KEPG`, version `1`, then
/// the same LZFSE payload with no header; it is read for migration only, with structural checks
/// but without the version 2 size and length policies, which its writer never applied.
///
/// `maximumDecodedBytes` bounds the decompressed JSON, not peak memory: a load also holds the
/// mapped file, the decoded record and the index it builds.
///
/// Synchronous and CPU-bound: call it from a nonisolated async context, never the main actor.
enum EPGCacheFormat {
    static let headerLength = 156
    static let fingerprintLength = 32

    private static let magic = Data("KEPG".utf8)
    private static let version1: UInt8 = 1
    private static let version2: UInt8 = 2
    private static let digestLength = 32
    /// Year 9999; also keeps every timestamp exactly representable as a double.
    private static let latestSeconds: Int64 = 253_402_300_799

    struct Limits: Sendable {
        var maximumFileBytes = 48 * 1024 * 1024
        var maximumDecodedBytes = 64 * 1024 * 1024
        /// Matches `EPGLimits.maximumIndexedPrograms`.
        var maximumPrograms = 200_000
        /// Matches `EPGLimits.maximumTextLength`, counted in characters.
        var maximumTextLength = 600
        var maximumNames = 200_000
        var maximumIdentifierBytes = 4_096
    }

    struct Header: Equatable, Sendable {
        let providerID: UUID
        let contentID: UUID
        let sourceFingerprint: Data
        let fetchedAt: Date
        /// Nil when the guide has no programmes.
        let coverage: DateInterval?
        let programCount: Int
        let channelCount: Int
        let compressedLength: Int
        let decompressedLength: Int
        let payloadDigest: Data
    }

    // MARK: - Version 2

    static func encode(_ index: EPGIndex, providerID: UUID, sourceFingerprint: Data, contentID: UUID = UUID(),
                       limits: Limits = Limits()) throws -> Data {
        guard sourceFingerprint.count == fingerprintLength else { throw EPGCacheFormatError.malformedHeader }
        let record = Record(index)
        guard record.rows.count <= limits.maximumPrograms else { throw EPGCacheFormatError.tooLarge }
        guard record.isStructurallyValid, record.meetsLimits(limits) else { throw EPGCacheFormatError.invalidRecord }
        let (json, compressed) = try encodePayload(record, limits: limits)
        guard headerLength + compressed.count <= limits.maximumFileBytes else { throw EPGCacheFormatError.tooLarge }
        let coverage = record.coverage

        var file = Data(capacity: headerLength + compressed.count)
        file.append(magic)
        file.append(contentsOf: [version2, 0, 0, 0])
        file.appendBigEndian(UInt32(headerLength))
        file.append(providerID.data)
        file.append(contentID.data)
        file.append(sourceFingerprint)
        file.appendBigEndian(record.fetchedAt.bitPattern)
        file.appendBigEndian(UInt64(bitPattern: coverage?.start ?? 0))
        file.appendBigEndian(UInt64(bitPattern: coverage?.end ?? 0))
        file.appendBigEndian(UInt32(record.rows.count))
        file.appendBigEndian(UInt32(record.channelIDs.count))
        file.appendBigEndian(UInt64(compressed.count))
        file.appendBigEndian(UInt64(json.count))
        file.append(contentsOf: SHA256.hash(data: compressed))
        assert(file.count == headerLength)
        file.append(compressed)
        return file
    }

    /// Reads and validates the header alone. `prefix` holds at least the file's first
    /// `headerLength` bytes; `fileSize` is the size of the whole file.
    static func header(of prefix: Data, fileSize: Int, limits: Limits = Limits()) throws -> Header {
        let bytes = Data(prefix.prefix(headerLength))
        guard bytes.count >= magic.count + 1, bytes.prefix(magic.count) == magic else {
            throw bytes.count < magic.count + 1 ? EPGCacheFormatError.truncated : EPGCacheFormatError.unrecognized
        }
        let version = bytes[magic.count]
        guard version == version2 else { throw EPGCacheFormatError.unsupportedVersion(version) }
        guard bytes.count == headerLength, fileSize >= headerLength else { throw EPGCacheFormatError.truncated }
        guard fileSize <= limits.maximumFileBytes else { throw EPGCacheFormatError.tooLarge }

        var reader = ByteReader(bytes, offset: 5)
        guard reader.bytes(3).allSatisfy({ $0 == 0 }), reader.uint32() == UInt32(headerLength) else {
            throw EPGCacheFormatError.malformedHeader
        }
        let providerID = UUID(data: reader.bytes(16))
        let contentID = UUID(data: reader.bytes(16))
        let fingerprint = reader.bytes(fingerprintLength)
        let fetchedAt = Double(bitPattern: reader.uint64())
        let coverageStart = Int64(bitPattern: reader.uint64())
        let coverageEnd = Int64(bitPattern: reader.uint64())
        let programCount = Int(reader.uint32())
        let channelCount = Int(reader.uint32())
        let compressedLength = reader.uint64()
        let decompressedLength = reader.uint64()
        let digest = reader.bytes(digestLength)

        guard isValidFetchTime(fetchedAt),
              programCount <= limits.maximumPrograms,
              channelCount <= programCount, (programCount == 0) == (channelCount == 0) else {
            throw EPGCacheFormatError.malformedHeader
        }
        let coverage: DateInterval?
        if programCount == 0 {
            guard coverageStart == 0, coverageEnd == 0 else { throw EPGCacheFormatError.malformedHeader }
            coverage = nil
        } else {
            guard isValidSeconds(coverageStart), isValidSeconds(coverageEnd), coverageStart < coverageEnd else {
                throw EPGCacheFormatError.malformedHeader
            }
            coverage = DateInterval(start: Date(timeIntervalSince1970: TimeInterval(coverageStart)),
                                    end: Date(timeIntervalSince1970: TimeInterval(coverageEnd)))
        }
        guard compressedLength > 0, compressedLength == UInt64(fileSize - headerLength) else {
            throw EPGCacheFormatError.lengthMismatch
        }
        guard decompressedLength > 0 else { throw EPGCacheFormatError.malformedHeader }
        guard decompressedLength <= UInt64(limits.maximumDecodedBytes) else { throw EPGCacheFormatError.tooLarge }

        return Header(providerID: providerID, contentID: contentID, sourceFingerprint: fingerprint,
                      fetchedAt: Date(timeIntervalSince1970: fetchedAt), coverage: coverage,
                      programCount: programCount, channelCount: channelCount,
                      compressedLength: Int(compressedLength), decompressedLength: Int(decompressedLength),
                      payloadDigest: digest)
    }

    /// Validates the whole file, then decodes it. The digest is checked before decompression, and
    /// the decoded record must agree with every header field.
    static func decode(_ file: Data, providerID: UUID,
                       limits: Limits = Limits()) throws -> (header: Header, index: EPGIndex) {
        let fileHeader = try header(of: file, fileSize: file.count, limits: limits)
        guard fileHeader.providerID == providerID else { throw EPGCacheFormatError.wrongProvider }
        let payload = file.dropFirst(headerLength)
        guard constantTimeEqual(Data(SHA256.hash(data: payload)), fileHeader.payloadDigest) else {
            throw EPGCacheFormatError.digestMismatch
        }
        let record = try decodePayload(payload, declaredLength: fileHeader.decompressedLength, limits: limits)
        guard record.meetsLimits(limits) else { throw EPGCacheFormatError.invalidRecord }
        guard Date(timeIntervalSince1970: record.fetchedAt) == fileHeader.fetchedAt,
              record.rows.count == fileHeader.programCount, record.channelIDs.count == fileHeader.channelCount,
              record.coverage?.start == fileHeader.coverage.map({ Int64($0.start.timeIntervalSince1970) }),
              record.coverage?.end == fileHeader.coverage.map({ Int64($0.end.timeIntervalSince1970) }) else {
            throw EPGCacheFormatError.mismatchedMetadata
        }
        guard let index = record.index() else { throw EPGCacheFormatError.invalidRecord }
        return (fileHeader, index)
    }

    // MARK: - Version 1

    /// Writes version 1 as the Milestone 1 writer did; until migration lands the store still uses it.
    static func encodeVersion1(_ index: EPGIndex, limits: Limits = Limits()) throws -> Data {
        let record = Record(index)
        guard record.isStructurallyValid else { throw EPGCacheFormatError.invalidRecord }
        let (_, compressed) = try encodePayload(record, limits: limits)
        var file = magic
        file.append(version1)
        file.append(compressed)
        guard file.count <= limits.maximumFileBytes else { throw EPGCacheFormatError.tooLarge }
        return file
    }

    /// Decodes a version 1 file. It declares no lengths, so its block headers and the decoded-size
    /// limit bound it. `tooLarge` means the file may be valid but exceeds this build's limits.
    static func decodeVersion1(_ file: Data, limits: Limits = Limits()) throws -> EPGIndex {
        guard file.count <= limits.maximumFileBytes else { throw EPGCacheFormatError.tooLarge }
        guard file.count > magic.count + 1 else { throw EPGCacheFormatError.truncated }
        guard file.prefix(magic.count) == magic else { throw EPGCacheFormatError.unrecognized }
        let version = file[file.startIndex + magic.count]
        guard version == version1 else { throw EPGCacheFormatError.unsupportedVersion(version) }
        let record = try decodePayload(file.dropFirst(magic.count + 1), declaredLength: nil, limits: limits)
        guard let index = record.index() else { throw EPGCacheFormatError.invalidRecord }
        return index
    }

    // MARK: - Payload

    /// Callers validate the record first, so the reader never rejects a file this writes.
    private static func encodePayload(_ record: Record, limits: Limits) throws -> (json: Data, compressed: Data) {
        let json = try JSONEncoder().encode(record)
        guard json.count <= limits.maximumDecodedBytes else { throw EPGCacheFormatError.tooLarge }
        return (json, try (json as NSData).compressed(using: .lzfse) as Data)
    }

    /// Streams the payload through a bounded LZFSE decoder into a buffer of exactly the size its
    /// block headers declare, which is checked against the limit before anything is allocated. The
    /// decoder itself also stops at that size. The buffer is released when this returns, before the
    /// caller builds the index. Not cancellable, so a cancelled caller cannot make a valid file look
    /// corrupt. Returns a structurally valid record; policy limits are the caller's choice.
    private static func decodePayload(_ payload: Data, declaredLength: Int?, limits: Limits) throws -> Record {
        guard let framing = lzfseFraming(payload), framing.length == payload.count else {
            throw EPGCacheFormatError.corruptPayload
        }
        guard framing.decodedBytes <= limits.maximumDecodedBytes else { throw EPGCacheFormatError.tooLarge }
        if let declaredLength, framing.decodedBytes != declaredLength { throw EPGCacheFormatError.lengthMismatch }
        guard framing.decodedBytes > 0 else { throw EPGCacheFormatError.corruptPayload }
        var json = Data()
        json.reserveCapacity(framing.decodedBytes)
        do {
            try payload.withUnsafeBytes { raw in
                try EPGPayloadDecoder.decode(raw.bindMemory(to: UInt8.self), algorithm: COMPRESSION_LZFSE,
                                             into: &json, maximumBytes: framing.decodedBytes,
                                             checksCancellation: false)
            }
        } catch EPGError.responseTooLarge {
            throw EPGCacheFormatError.corruptPayload  // blocks produced more than they declared
        } catch EPGError.corruptCompressedData {
            throw EPGCacheFormatError.corruptPayload
        }
        guard json.count == framing.decodedBytes else { throw EPGCacheFormatError.corruptPayload }
        guard let record = try? JSONDecoder().decode(Record.self, from: json),
              record.isStructurallyValid else { throw EPGCacheFormatError.invalidRecord }
        return record
    }

    /// Walks LZFSE block headers without decoding, returning the length of the first stream and the
    /// size its blocks declare. Apple's stream decoder stops at the end-of-stream block but consumes
    /// whatever follows it, so trailing or concatenated data is found here instead. Block layouts
    /// follow the LZFSE reference implementation (`lzfse_internal.h`, lzfse/lzfse@e634ca58); an
    /// unknown or overrunning block returns nil.
    static func lzfseFraming(_ payload: Data) -> (length: Int, decodedBytes: Int)? {
        payload.withUnsafeBytes { raw -> (length: Int, decodedBytes: Int)? in
            func little(_ offset: Int, _ width: Int) -> UInt64? {
                guard offset >= 0, offset + width <= raw.count else { return nil }
                return (0..<width).reduce(UInt64(0)) { $0 | UInt64(raw[offset + $1]) << (8 * UInt64($1)) }
            }
            var offset = 0
            var decodedBytes = 0
            while let magic = little(offset, 4) {
                let blockLength: UInt64
                switch magic {
                case 0x2478_7662:  // "bvx$": end of stream
                    return (offset + 4, decodedBytes)
                case 0x2D78_7662:  // "bvx-": raw size, then the raw bytes
                    guard let rawBytes = little(offset + 4, 4) else { return nil }
                    blockLength = 8 + rawBytes
                case 0x6E78_7662:  // "bvxn": LZVN; raw size, payload size, then the payload
                    guard let payloadBytes = little(offset + 8, 4) else { return nil }
                    blockLength = 12 + payloadBytes
                case 0x3178_7662:  // "bvx1": the C header struct, 772 bytes with padding, then the payloads
                    guard let literalBytes = little(offset + 20, 4), let commandBytes = little(offset + 24, 4) else {
                        return nil
                    }
                    blockLength = 772 + literalBytes + commandBytes
                case 0x3278_7662:  // "bvx2": header size and payload sizes are packed bit fields
                    guard let fields0 = little(offset + 8, 8), let fields1 = little(offset + 16, 8),
                          let fields2 = little(offset + 24, 8) else { return nil }
                    let headerBytes = fields2 & 0xFFFF_FFFF
                    guard headerBytes >= 32 else { return nil }
                    let literalBytes = (fields0 >> 20) & 0xF_FFFF
                    let commandBytes = (fields1 >> 40) & 0xF_FFFF
                    blockLength = headerBytes + literalBytes + commandBytes
                default:
                    return nil
                }
                guard let rawBytes = little(offset + 4, 4), blockLength <= UInt64(raw.count - offset) else {
                    return nil
                }
                offset += Int(blockLength)
                decodedBytes += Int(rawBytes)
                // Larger than any cache could be; also keeps the sum far from overflow.
                guard decodedBytes <= Int(UInt32.max) else { return nil }
            }
            return nil
        }
    }

    private static func isValidSeconds(_ value: Int64) -> Bool { (0...latestSeconds).contains(value) }

    private static func isValidFetchTime(_ value: Double) -> Bool {
        value.isFinite && value >= 0 && value <= Double(latestSeconds)
    }

    private static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    /// Compact JSON form shared by both versions: channel IDs are stored once, times as whole seconds.
    private struct Record: Codable {
        struct Row: Codable {
            let c: Int
            let s: Int64
            let d: Int32
            let t: String
            let st: String?
            let ds: String?
            let g: String?
            let e: String?
        }

        let fetchedAt: Double
        let channelIDs: [String]
        let names: [String: String]
        let rows: [Row]

        init(_ index: EPGIndex) {
            var channelIDs: [String] = []
            var positions: [String: Int] = [:]
            var rows: [Row] = []
            rows.reserveCapacity(index.programCount)
            for key in index.programsByChannel.keys.sorted() {
                for program in index.programsByChannel[key] ?? [] {
                    let position: Int
                    if let existing = positions[program.channelID] { position = existing } else {
                        position = channelIDs.count
                        positions[program.channelID] = position
                        channelIDs.append(program.channelID)
                    }
                    let start = Self.seconds(program.start)
                    let duration = Int32(clamping: Self.seconds(program.end) - start)
                    rows.append(Row(c: position, s: start, d: duration, t: program.title, st: program.subtitle,
                                    ds: program.summary, g: program.category, e: program.episode))
                }
            }
            fetchedAt = index.fetchedAt.timeIntervalSince1970
            self.channelIDs = channelIDs
            names = index.channelIDsByName
            self.rows = rows
        }

        /// Whole seconds since 1970, clamped just outside the valid range so validation rejects it
        /// instead of the conversion trapping.
        private static func seconds(_ date: Date) -> Int64 {
            let value = date.timeIntervalSince1970.rounded()
            guard value.isFinite else { return -1 }
            return Int64(min(max(value, -1), Double(latestSeconds) + 1))
        }

        /// End of a row in whole seconds, or nil if the addition overflows.
        private static func end(_ row: Row) -> Int64? {
            let (end, overflow) = row.s.addingReportingOverflow(Int64(row.d))
            return overflow ? nil : end
        }

        /// Earliest start and latest end in whole seconds; nil without programmes or on overflow.
        var coverage: (start: Int64, end: Int64)? {
            var range: (start: Int64, end: Int64)?
            for row in rows {
                guard let end = Self.end(row) else { return nil }
                range = (min(range?.start ?? row.s, row.s), max(range?.end ?? end, end))
            }
            return range
        }

        /// Checks every version needs before an index is built: times and indexes in range.
        var isStructurallyValid: Bool {
            guard isValidFetchTime(fetchedAt) else { return false }
            return rows.allSatisfy { row in
                guard channelIDs.indices.contains(row.c), row.d > 0, isValidSeconds(row.s),
                      let end = Self.end(row) else { return false }
                return isValidSeconds(end)
            }
        }

        /// Version 2 policy: bounds every count and string, which the Milestone 1 writer did not.
        func meetsLimits(_ limits: Limits) -> Bool {
            guard rows.count <= limits.maximumPrograms,
                  channelIDs.count <= rows.count, names.count <= limits.maximumNames,
                  Set(channelIDs).count == channelIDs.count,
                  channelIDs.allSatisfy({ $0.utf8.count <= limits.maximumIdentifierBytes }),
                  names.allSatisfy({ $0.key.utf8.count <= limits.maximumIdentifierBytes
                                     && $0.value.utf8.count <= limits.maximumIdentifierBytes }) else {
                return false
            }
            func fits(_ text: String?) -> Bool { (text?.count ?? 0) <= limits.maximumTextLength }
            return rows.allSatisfy { fits($0.t) && fits($0.st) && fits($0.ds) && fits($0.g) && fits($0.e) }
        }

        func index() -> EPGIndex? {
            var grouped: [String: [EPGProgram]] = [:]
            for row in rows {
                guard channelIDs.indices.contains(row.c), row.d > 0,
                      let key = EPGChannelKey.guideID(channelIDs[row.c]) else { return nil }
                let start = Date(timeIntervalSince1970: TimeInterval(row.s))
                grouped[key, default: []].append(EPGProgram(
                    channelID: channelIDs[row.c], start: start, end: start.addingTimeInterval(TimeInterval(row.d)),
                    title: row.t, subtitle: row.st, summary: row.ds, category: row.g, episode: row.e))
            }
            // Rows were written in airing order per channel; reject a file that is not.
            for list in grouped.values where zip(list, list.dropFirst()).contains(where: { $0.end > $1.start }) {
                return nil
            }
            return EPGIndex(fetchedAt: Date(timeIntervalSince1970: fetchedAt), programsByChannel: grouped,
                            channelIDsByName: names, statistics: EPGIndex.Statistics())
        }
    }
}

enum EPGCacheFormatError: Error, Equatable, Sendable {
    case truncated
    case unrecognized
    case unsupportedVersion(UInt8)
    case malformedHeader
    case lengthMismatch
    case tooLarge
    case wrongProvider
    case digestMismatch
    case corruptPayload
    case invalidRecord
    case mismatchedMetadata
}

/// Sequential big-endian reads over a buffer whose length the caller has already checked.
private struct ByteReader {
    private let data: Data
    private var offset: Int

    init(_ data: Data, offset: Int) {
        self.data = data
        self.offset = data.startIndex + offset
    }

    mutating func bytes(_ count: Int) -> Data {
        defer { offset += count }
        return Data(data[offset..<offset + count])
    }

    mutating func uint32() -> UInt32 { bytes(4).reduce(0) { $0 << 8 | UInt32($1) } }
    mutating func uint64() -> UInt64 { bytes(8).reduce(0) { $0 << 8 | UInt64($1) } }
}

private extension Data {
    mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }
}

private extension UUID {
    init(data: Data) {
        var bytes = uuid_t(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        Swift.withUnsafeMutableBytes(of: &bytes) { $0.copyBytes(from: data.prefix(16)) }
        self.init(uuid: bytes)
    }

    var data: Data { Swift.withUnsafeBytes(of: uuid) { Data($0) } }
}
