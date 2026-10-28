import Foundation

/// Reads a WebM/Opus file as it arrives, so it can play while it downloads (see `OpusStream`):
/// the head (channels, pre-skip, length) as soon as it is in, then the Opus packets of every
/// block, whatever the sizes of the pieces the bytes come in. Elements it has no use for (the
/// index, tags) are skipped without being kept in memory.
struct WebMStreamParser {
    struct Head: Equatable, Sendable {
        var channels = 2
        var preSkip = 0
        /// Seconds, from the segment's info; nil when the file doesn't say.
        var duration: Double?
        /// Nanoseconds per timecode unit.
        var timecodeScale = 1_000_000
    }

    struct Packet: Sendable {
        let data: Data
        /// Seconds from the start of the file (the block's timecode).
        let time: Double
    }

    enum ParseError: Error, Equatable {
        case notWebM
        case notOpus
    }

    /// Samples per packet at 48 kHz, from a packet's TOC byte (RFC 6716 §3.1).
    static func framesPerPacket(_ packet: Data) -> UInt32 {
        guard let toc = packet.first else { return 960 }
        let config = Int(toc >> 3)
        let frameSize: Int
        switch config {
        case 0...11: frameSize = [480, 960, 1920, 2880][config % 4]
        case 12...15: frameSize = [480, 960][config % 2]
        default: frameSize = [120, 240, 480, 960][config % 4]
        }
        let frames: Int
        switch toc & 0x03 {
        case 0: frames = 1
        case 1, 2: frames = 2
        default: frames = packet.count > 1 ? max(1, Int(packet[packet.startIndex + 1] & 0x3F)) : 1
        }
        return UInt32(frameSize * frames)
    }

    private(set) var head = Head()
    /// The clusters (the audio) have started: the head is complete.
    private(set) var headIsComplete = false
    /// How many bytes of the file have been read.
    private(set) var consumed = 0

    private var buffer: [UInt8] = []
    /// Bytes still to drop of an element that isn't needed.
    private var skipping = 0
    private var startedHeader = false
    private var isOpus = false
    private var clusterTimecode = 0

    // Element IDs
    private static let ebmlHeader: UInt32 = 0x1A45_DFA3
    private static let cluster: UInt32 = 0x1F43_B675
    private static let masters: Set<UInt32> = [
        0x1853_8067, // Segment
        0x1549_A966, // Info
        cluster,
        0x1654_AE6B, // Tracks
        0xAE,        // TrackEntry
        0xA0,        // BlockGroup
    ]
    private static let timecodeScale: UInt32 = 0x2A_D7B1
    private static let duration: UInt32 = 0x4489
    private static let codecID: UInt32 = 0x86
    private static let codecPrivate: UInt32 = 0x63A2
    private static let timecode: UInt32 = 0xE7
    private static let simpleBlock: UInt32 = 0xA3
    private static let block: UInt32 = 0xA1
    private static let kept: Set<UInt32> = [timecodeScale, duration, codecID, codecPrivate, timecode, simpleBlock, block]

    /// Reads the next bytes of the file; returns the packets they complete.
    mutating func append(_ data: Data) throws -> [Packet] {
        buffer.append(contentsOf: data)
        var packets: [Packet] = []
        var position = 0
        while position < buffer.count {
            if skipping > 0 {
                let count = min(skipping, buffer.count - position)
                position += count
                skipping -= count
                continue
            }
            let start = position
            let idRead = Self.readID(buffer, &position)
            guard case .value(let id) = idRead else {
                if case .invalid = idRead { throw ParseError.notWebM }
                position = start
                break
            }
            let sizeRead = Self.readSize(buffer, &position)
            guard case .value(let size) = sizeRead else {
                if case .invalid = sizeRead { throw ParseError.notWebM }
                position = start
                break
            }
            if !startedHeader {
                guard id == Self.ebmlHeader else { throw ParseError.notWebM }
                startedHeader = true
            }
            if Self.masters.contains(id) {
                // Its children follow directly.
                if id == Self.cluster {
                    guard isOpus else { throw ParseError.notOpus }
                    headIsComplete = true
                }
                continue
            }
            guard let length = size else { throw ParseError.notWebM }
            guard Self.kept.contains(id) else {
                let count = min(length, buffer.count - position)
                position += count
                skipping = length - count
                continue
            }
            guard position + length <= buffer.count else {
                // Wait for the rest of the element.
                position = start
                break
            }
            try read(id, buffer[position..<(position + length)], into: &packets)
            position += length
        }
        buffer.removeFirst(position)
        consumed += position
        return packets
    }

    private mutating func read(_ id: UInt32, _ body: ArraySlice<UInt8>, into packets: inout [Packet]) throws {
        switch id {
        case Self.timecodeScale:
            head.timecodeScale = Int(Self.unsigned(body))
        case Self.duration:
            let value: Double
            if body.count == 4 {
                value = Double(Float(bitPattern: UInt32(Self.unsigned(body))))
            } else if body.count == 8 {
                value = Double(bitPattern: Self.unsigned(body))
            } else {
                return
            }
            head.duration = value * Double(head.timecodeScale) / 1e9
        case Self.codecID:
            isOpus = String(decoding: body, as: UTF8.self) == "A_OPUS"
        case Self.codecPrivate where body.count >= 19:
            // OpusHead: "OpusHead", version, channel count, pre-skip (LE16), ...
            let base = body.startIndex
            head.channels = Int(body[base + 9])
            head.preSkip = Int(body[base + 10]) | Int(body[base + 11]) << 8
        case Self.timecode:
            clusterTimecode = Int(Self.unsigned(body))
        case Self.simpleBlock, Self.block:
            packets.append(contentsOf: frames(inBlock: body))
        default:
            break
        }
    }

    /// The frames of a (Simple)Block: track number, 16-bit timecode, flags, then the laced frames.
    private func frames(inBlock body: ArraySlice<UInt8>) -> [Packet] {
        let bytes = Array(body)
        var position = 0
        guard case .value = Self.readSize(bytes, &position), position + 3 <= bytes.count else { return [] }
        let relative = Int(Int16(bitPattern: UInt16(bytes[position]) << 8 | UInt16(bytes[position + 1])))
        let time = Double(clusterTimecode + relative) * Double(head.timecodeScale) / 1e9
        let flags = bytes[position + 2]
        position += 3
        let end = bytes.count

        var sizes: [Int] = []
        switch (flags >> 1) & 0x03 {
        case 0: // no lacing
            sizes = [end - position]
        case 1: // Xiph lacing
            guard position < end else { return [] }
            let count = Int(bytes[position]) + 1
            position += 1
            for _ in 0..<(count - 1) {
                var size = 0
                while position < end {
                    let byte = Int(bytes[position])
                    position += 1
                    size += byte
                    if byte != 255 { break }
                }
                sizes.append(size)
            }
            sizes.append(end - position - sizes.reduce(0, +))
        case 2: // fixed-size lacing
            guard position < end else { return [] }
            let count = Int(bytes[position]) + 1
            position += 1
            sizes = Array(repeating: (end - position) / count, count: count)
        default: // EBML lacing
            guard position < end else { return [] }
            let count = Int(bytes[position]) + 1
            position += 1
            guard let first = Self.readVint(bytes, &position) else { return [] }
            var previous = Int(first.value)
            sizes.append(previous)
            for _ in 0..<max(0, count - 2) {
                guard let delta = Self.readVint(bytes, &position) else { return [] }
                let bias = (1 << (7 * delta.length - 1)) - 1
                previous += Int(delta.value) - bias
                sizes.append(previous)
            }
            sizes.append(end - position - sizes.reduce(0, +))
        }

        var frames: [Packet] = []
        for size in sizes {
            guard size > 0, position + size <= end else { break }
            frames.append(Packet(data: Data(bytes[position..<(position + size)]), time: time))
            position += size
        }
        return frames
    }

    // MARK: EBML variable-length integers

    private enum Read<Value> {
        case value(Value)
        /// The bytes so far end in the middle of it.
        case incomplete
        case invalid
    }

    private static func unsigned(_ body: ArraySlice<UInt8>) -> UInt64 {
        body.prefix(8).reduce(0) { $0 << 8 | UInt64($1) }
    }

    /// Element IDs keep their length marker bits.
    private static func readID(_ bytes: [UInt8], _ position: inout Int) -> Read<UInt32> {
        guard position < bytes.count else { return .incomplete }
        let length = bytes[position].leadingZeroBitCount + 1
        guard length <= 4 else { return .invalid }
        guard position + length <= bytes.count else { return .incomplete }
        var value: UInt32 = 0
        for offset in 0..<length { value = value << 8 | UInt32(bytes[position + offset]) }
        position += length
        return .value(value)
    }

    /// A size; nil inside `.value` when it is unknown (all ones).
    private static func readSize(_ bytes: [UInt8], _ position: inout Int) -> Read<Int?> {
        guard position < bytes.count else { return .incomplete }
        guard bytes[position] != 0 else { return .invalid }
        guard let vint = readVint(bytes, &position) else { return .incomplete }
        let allOnes: UInt64 = (1 << (7 * UInt64(vint.length))) - 1
        if vint.value == allOnes { return .value(nil) }
        guard vint.value <= UInt64(Int.max) else { return .invalid }
        return .value(Int(vint.value))
    }

    /// Value with the length marker removed, plus the number of bytes used.
    private static func readVint(_ bytes: [UInt8], _ position: inout Int) -> (value: UInt64, length: Int)? {
        guard position < bytes.count, bytes[position] != 0 else { return nil }
        let first = bytes[position]
        let length = first.leadingZeroBitCount + 1
        guard position + length <= bytes.count else { return nil }
        let mask: UInt8 = length >= 8 ? 0 : 0xFF >> UInt8(length)
        var value = UInt64(first & mask)
        for offset in 1..<max(1, length) {
            value = value << 8 | UInt64(bytes[position + offset])
        }
        position += length
        return (value, length)
    }
}
