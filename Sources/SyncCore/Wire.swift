import Foundation

/// Wire protocol: every UDP datagram is one message.
///
/// Layout (all integers little-endian):
///   magic   u32  "ASYN" (0x4E595341 as LE bytes 'A','S','Y','N')
///   version u8   currently 1
///   type    u8   PacketType
///   payload      type-specific
public enum Message: Equatable {
    /// Client -> server: announce presence (also acts as a NAT/conntrack keepalive).
    case hello
    /// Client -> server clock probe. `clientSendNs` is t1 on the client clock.
    case clockRequest(clientSendNs: UInt64)
    /// Server -> client clock answer: echoes t1, adds t2 (server receive) and
    /// t3 (server send), both on the master clock.
    case clockReply(clientSendNs: UInt64, serverRecvNs: UInt64, serverSendNs: UInt64)
    /// Server -> client audio chunk.
    case audio(AudioChunk)
}

public enum PacketType: UInt8 {
    case hello = 1
    case clockRequest = 2
    case clockReply = 3
    case audio = 4
}

public enum WireError: Error, Equatable {
    case truncated
    case badMagic
    case unsupportedVersion(UInt8)
    case unknownType(UInt8)
    case badPayload(String)
}

public enum Wire {
    public static let magic: [UInt8] = [0x41, 0x53, 0x59, 0x4E] // "ASYN"
    public static let version: UInt8 = 1
    /// Keep audio datagrams under a typical 1500-byte MTU to avoid IP
    /// fragmentation (one lost fragment would drop the whole packet).
    /// 160 frames * 2 ch * 4 bytes = 1280 bytes of payload.
    public static let maxFramesPerPacket = 160

    // MARK: - Encode

    public static func encode(_ message: Message) -> Data {
        var w = BinaryWriter()
        w.putBytes(magic)
        w.put(version)
        switch message {
        case .hello:
            w.put(PacketType.hello.rawValue)
        case .clockRequest(let t1):
            w.put(PacketType.clockRequest.rawValue)
            w.put(t1)
        case .clockReply(let t1, let t2, let t3):
            w.put(PacketType.clockReply.rawValue)
            w.put(t1)
            w.put(t2)
            w.put(t3)
        case .audio(let chunk):
            w.put(PacketType.audio.rawValue)
            w.put(chunk.sequence)
            w.put(chunk.playAtMasterNs)
            w.put(UInt32(chunk.sampleRate.rounded()))
            w.put(UInt16(chunk.channels))
            w.put(UInt32(chunk.frameCount))
            w.put(chunk.samples)
        }
        return w.data
    }

    // MARK: - Decode

    public static func decode(_ data: Data) throws -> Message {
        var r = BinaryReader(data)
        let m = try r.bytes(4)
        guard m == magic else { throw WireError.badMagic }
        let v = try r.u8()
        guard v == version else { throw WireError.unsupportedVersion(v) }
        let rawType = try r.u8()
        guard let type = PacketType(rawValue: rawType) else { throw WireError.unknownType(rawType) }

        switch type {
        case .hello:
            return .hello
        case .clockRequest:
            return .clockRequest(clientSendNs: try r.u64())
        case .clockReply:
            return .clockReply(
                clientSendNs: try r.u64(),
                serverRecvNs: try r.u64(),
                serverSendNs: try r.u64()
            )
        case .audio:
            let sequence = try r.u32()
            let playAt = try r.u64()
            let sampleRate = try r.u32()
            let channels = try r.u16()
            let frameCount = try r.u32()
            guard sampleRate > 0 else { throw WireError.badPayload("zero sample rate") }
            guard channels > 0 && channels <= 8 else { throw WireError.badPayload("bad channel count \(channels)") }
            guard frameCount <= 1 << 16 else { throw WireError.badPayload("absurd frame count \(frameCount)") }
            let samples = try r.floats(count: Int(frameCount) * Int(channels))
            return .audio(AudioChunk(
                sequence: sequence,
                playAtMasterNs: playAt,
                sampleRate: Double(sampleRate),
                channels: Int(channels),
                samples: samples
            ))
        }
    }
}

// MARK: - Binary helpers

public struct BinaryWriter {
    public private(set) var data = Data()
    public init() {}

    public mutating func putBytes(_ bytes: [UInt8]) { data.append(contentsOf: bytes) }
    public mutating func put(_ v: UInt8) { data.append(v) }

    public mutating func put(_ v: UInt16) {
        data.append(UInt8(truncatingIfNeeded: v))
        data.append(UInt8(truncatingIfNeeded: v >> 8))
    }

    public mutating func put(_ v: UInt32) {
        for shift in stride(from: 0, to: 32, by: 8) {
            data.append(UInt8(truncatingIfNeeded: v >> shift))
        }
    }

    public mutating func put(_ v: UInt64) {
        for shift in stride(from: 0, to: 64, by: 8) {
            data.append(UInt8(truncatingIfNeeded: v >> shift))
        }
    }

    public mutating func put(_ floats: [Float]) {
        data.reserveCapacity(data.count + floats.count * 4)
        for f in floats {
            put(f.bitPattern)
        }
    }
}

public struct BinaryReader {
    private let bytes: [UInt8]
    private var offset = 0

    public init(_ data: Data) {
        self.bytes = [UInt8](data)
    }

    public var remaining: Int { bytes.count - offset }

    public mutating func bytes(_ count: Int) throws -> [UInt8] {
        guard remaining >= count else { throw WireError.truncated }
        defer { offset += count }
        return Array(bytes[offset..<offset + count])
    }

    public mutating func u8() throws -> UInt8 {
        guard remaining >= 1 else { throw WireError.truncated }
        defer { offset += 1 }
        return bytes[offset]
    }

    public mutating func u16() throws -> UInt16 {
        guard remaining >= 2 else { throw WireError.truncated }
        defer { offset += 2 }
        return UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    public mutating func u32() throws -> UInt32 {
        guard remaining >= 4 else { throw WireError.truncated }
        defer { offset += 4 }
        var v: UInt32 = 0
        for i in 0..<4 { v |= UInt32(bytes[offset + i]) << (8 * i) }
        return v
    }

    public mutating func u64() throws -> UInt64 {
        guard remaining >= 8 else { throw WireError.truncated }
        defer { offset += 8 }
        var v: UInt64 = 0
        for i in 0..<8 { v |= UInt64(bytes[offset + i]) << (8 * i) }
        return v
    }

    public mutating func floats(count: Int) throws -> [Float] {
        guard remaining >= count * 4 else { throw WireError.truncated }
        var out = [Float]()
        out.reserveCapacity(count)
        for _ in 0..<count {
            out.append(Float(bitPattern: try u32()))
        }
        return out
    }
}
