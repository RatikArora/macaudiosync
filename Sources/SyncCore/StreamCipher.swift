import Foundation
import CryptoKit

/// Optional authenticated encryption for the wire protocol.
///
/// When both sides share a passphrase, every datagram (audio, clock probes,
/// hello) is sealed with ChaCha20-Poly1305 under a key derived via
/// HKDF-SHA256. This gives two guarantees on a hostile LAN:
///  - confidentiality: nobody without the passphrase can listen to the
///    captured system audio (which can include calls, videos, anything), and
///  - authenticity: receivers only play audio from a sender that knows the
///    passphrase; forged/tampered packets fail the AEAD tag and are dropped.
///
/// Sealed datagrams are framed as: "ASYE" + 12-byte nonce + ciphertext+tag.
/// Without a passphrase the wire stays plaintext ("ASYN" frames) — fine on a
/// trusted home network; set a key on shared Wi-Fi.
public struct StreamCipher {
    public static let magic: [UInt8] = [0x41, 0x53, 0x59, 0x45] // "ASYE"

    private let key: SymmetricKey

    public init(passphrase: String) {
        key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: Data(passphrase.utf8)),
            salt: Data("MacAudioSync.v1".utf8),
            info: Data("stream".utf8),
            outputByteCount: 32
        )
    }

    /// Encrypt + authenticate one datagram (fresh random nonce per packet).
    public func seal(_ plaintext: Data) -> Data {
        // ChaChaPoly.seal only throws for invalid key sizes; ours is fixed.
        let box = try! ChaChaPoly.seal(plaintext, using: key)
        var out = Data(Self.magic)
        out.append(box.combined)
        return out
    }

    /// Decrypt + verify one datagram. Throws on wrong key, tampering, or
    /// malformed framing.
    public func open(_ data: Data) throws -> Data {
        guard Self.looksSealed(data), data.count > 4 + 12 + 16 else {
            throw WireError.truncated
        }
        let box = try ChaChaPoly.SealedBox(combined: data.dropFirst(4))
        return try ChaChaPoly.open(box, using: key)
    }

    public static func looksSealed(_ data: Data) -> Bool {
        data.count >= 4 && data.prefix(4).elementsEqual(magic)
    }
}
