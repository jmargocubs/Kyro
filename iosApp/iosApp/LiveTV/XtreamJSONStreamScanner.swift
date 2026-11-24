import Foundation

/// Splits an Xtream JSON response body into its top-level members without materializing the whole document.
struct XtreamJSONStreamScanner {
    enum StreamError: Error, Sendable { case invalidResponse }
    enum Shape: Equatable, Sendable { case unknown, array, object, null }

    struct Member: Equatable, Sendable {
        let bytes: [UInt8]?
        let key: String?
        let isObject: Bool
        let isOversized: Bool
    }

    enum Capture: Sendable {
        case all
        case accountOnly
    }

    let maximumMemberBytes: Int
    let capture: Capture
    private(set) var shape: Shape = .unknown
    private(set) var isComplete = false
    private(set) var stopped = false

    private enum Phase {
        case start, nullLiteral, expectMember, expectKey, key, colon, expectMemberValue
        case compound, stringScalar, bareScalar, trailing
    }

    private var phase: Phase = .start
    private var depth = 0
    private var inString = false
    private var escaped = false
    private var buffer: [UInt8] = []
    private var memberLength = 0
    private var oversized = false
    private var capturing = false
    private var memberIsObject = false
    private var keyBytes: [UInt8] = []
    private var currentKey: String?
    private var literal: [UInt8] = []

    init(maximumMemberBytes: Int, capture: Capture = .all) {
        self.maximumMemberBytes = max(1, maximumMemberBytes)
        self.capture = capture
    }

    /// Feeds the next chunk. `emit` returns `false` to stop scanning early.
    @discardableResult
    mutating func consume(_ chunk: UnsafeBufferPointer<UInt8>, emit: (Member) throws -> Bool) throws -> Bool {
        guard !stopped else { return false }
        var index = 0
        let count = chunk.count
        while index < count {
            let byte = chunk[index]
            switch phase {
            case .start:
                if Self.isWhitespaceOrBOM(byte) { break }
                switch byte {
                case UInt8(ascii: "["): shape = .array; phase = .expectMember
                case UInt8(ascii: "{"): shape = .object; phase = .expectKey
                case UInt8(ascii: "n"): shape = .null; phase = .nullLiteral; literal = [byte]
                default: throw StreamError.invalidResponse
                }
            case .nullLiteral:
                literal.append(byte)
                if literal.count == 4 {
                    guard literal == Array("null".utf8) else { throw StreamError.invalidResponse }
                    isComplete = true
                    phase = .trailing
                }
            case .expectMember:
                if Self.isWhitespace(byte) || byte == UInt8(ascii: ",") { break }
                if byte == UInt8(ascii: "]") { isComplete = true; phase = .trailing; break }
                currentKey = nil
                beginMember(byte)
            case .expectKey:
                if Self.isWhitespace(byte) || byte == UInt8(ascii: ",") { break }
                if byte == UInt8(ascii: "}") { isComplete = true; phase = .trailing; break }
                guard byte == UInt8(ascii: "\"") else { throw StreamError.invalidResponse }
                keyBytes.removeAll(keepingCapacity: true)
                escaped = false
                phase = .key
            case .key:
                if escaped {
                    escaped = false
                    appendKeyByte(byte)
                } else if byte == UInt8(ascii: "\\") {
                    escaped = true
                    appendKeyByte(byte)
                } else if byte == UInt8(ascii: "\"") {
                    currentKey = String(decoding: keyBytes, as: UTF8.self)
                    phase = .colon
                } else {
                    appendKeyByte(byte)
                }
            case .colon:
                if Self.isWhitespace(byte) { break }
                guard byte == UInt8(ascii: ":") else { throw StreamError.invalidResponse }
                phase = .expectMemberValue
            case .expectMemberValue:
                if Self.isWhitespace(byte) { break }
                beginMember(byte)
            case .compound:
                index = try scanCompound(chunk, from: index, emit: emit)
                if stopped { return false }
                continue
            case .stringScalar:
                if escaped { escaped = false }
                else if byte == UInt8(ascii: "\\") { escaped = true }
                else if byte == UInt8(ascii: "\"") { finishScalar() }
            case .bareScalar:
                if Self.isWhitespace(byte) || byte == UInt8(ascii: ",") || byte == UInt8(ascii: "]")
                    || byte == UInt8(ascii: "}") {
                    finishScalar()
                    continue
                }
            case .trailing:
                return true
            }
            index += 1
        }
        return true
    }

    mutating func finish() throws {
        if stopped { return }
        switch phase {
        case .start:
            shape = .null
            isComplete = true
        case .trailing:
            break
        default:
            throw StreamError.invalidResponse
        }
    }

    private mutating func beginMember(_ byte: UInt8) {
        switch byte {
        case UInt8(ascii: "{"), UInt8(ascii: "["):
            memberIsObject = byte == UInt8(ascii: "{")
            depth = 1
            inString = false
            escaped = false
            oversized = false
            memberLength = 1
            capturing = shouldCapture
            buffer.removeAll(keepingCapacity: true)
            if capturing { buffer.append(byte) }
            phase = .compound
        case UInt8(ascii: "\""):
            escaped = false
            phase = .stringScalar
        default:
            phase = .bareScalar
        }
    }

    private var shouldCapture: Bool {
        switch capture {
        case .all: return true
        case .accountOnly: return currentKey == "user_info"
        }
    }

    private mutating func finishScalar() {
        phase = shape == .object ? .expectKey : .expectMember
    }

    private mutating func scanCompound(_ chunk: UnsafeBufferPointer<UInt8>, from start: Int,
                                       emit: (Member) throws -> Bool) throws -> Int {
        var index = start
        let count = chunk.count
        while index < count {
            let byte = chunk[index]
            if inString {
                if escaped { escaped = false }
                else if byte == UInt8(ascii: "\\") { escaped = true }
                else if byte == UInt8(ascii: "\"") { inString = false }
            } else {
                switch byte {
                case UInt8(ascii: "\""):
                    inString = true
                case UInt8(ascii: "{"), UInt8(ascii: "["):
                    depth += 1
                case UInt8(ascii: "}"), UInt8(ascii: "]"):
                    depth -= 1
                    if depth == 0 {
                        appendRun(chunk, from: start, through: index)
                        let member = Member(bytes: capturing && !oversized ? buffer : nil, key: currentKey,
                                            isObject: memberIsObject, isOversized: oversized)
                        buffer.removeAll(keepingCapacity: !oversized)
                        phase = shape == .object ? .expectKey : .expectMember
                        if try !emit(member) { stopped = true }
                        return index + 1
                    }
                default:
                    break
                }
            }
            index += 1
        }
        appendRun(chunk, from: start, through: count - 1)
        return count
    }

    private mutating func appendRun(_ chunk: UnsafeBufferPointer<UInt8>, from start: Int, through end: Int) {
        guard end >= start else { return }
        let length = end - start + 1
        memberLength += length
        if !oversized && memberLength > maximumMemberBytes {
            oversized = true
            buffer.removeAll(keepingCapacity: false)
        }
        if capturing && !oversized {
            buffer.append(contentsOf: UnsafeBufferPointer(rebasing: chunk[start...end]))
        }
    }

    private mutating func appendKeyByte(_ byte: UInt8) {
        if keyBytes.count < 64 { keyBytes.append(byte) }
    }

    private static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x0A || byte == 0x0D || byte == 0x09
    }

    private static func isWhitespaceOrBOM(_ byte: UInt8) -> Bool {
        isWhitespace(byte) || byte == 0xEF || byte == 0xBB || byte == 0xBF
    }
}
