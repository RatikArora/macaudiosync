import Testing
import Foundation
@testable import SyncCore

@Suite struct StreamCipherTests {

    @Test func sealOpenRoundTripPreservesWireMessages() throws {
        let cipher = StreamCipher(passphrase: "correct horse battery staple")
        let chunk = AudioChunk(
            sequence: 42, playAtMasterNs: 123_456_789, sampleRate: 48_000, channels: 2,
            samples: (0..<320).map { Float($0) / 320 }
        )
        let plaintext = Wire.encode(.audio(chunk))
        let sealed = cipher.seal(plaintext)
        #expect(StreamCipher.looksSealed(sealed))
        #expect(!StreamCipher.looksSealed(plaintext), "plaintext frames must not look sealed")
        let opened = try cipher.open(sealed)
        #expect(opened == plaintext)
        #expect(try Wire.decode(opened) == .audio(chunk))
    }

    @Test func wrongPassphraseFailsToOpen() {
        let alice = StreamCipher(passphrase: "party-at-ratiks")
        let mallory = StreamCipher(passphrase: "party-at-ratikz")
        let sealed = alice.seal(Wire.encode(.hello))
        #expect(throws: (any Error).self) { try mallory.open(sealed) }
    }

    @Test func tamperedPacketIsRejected() throws {
        let cipher = StreamCipher(passphrase: "secret")
        var sealed = cipher.seal(Wire.encode(.clockRequest(clientSendNs: 1_000)))
        sealed[sealed.count - 5] ^= 0x01 // flip one ciphertext bit
        #expect(throws: (any Error).self) { try cipher.open(sealed) }
    }

    @Test func noncesAreFreshPerPacket() {
        let cipher = StreamCipher(passphrase: "secret")
        let a = cipher.seal(Wire.encode(.hello))
        let b = cipher.seal(Wire.encode(.hello))
        #expect(a != b, "identical plaintexts must produce distinct ciphertexts")
    }

    @Test func plaintextAndGarbageRejectedByOpen() {
        let cipher = StreamCipher(passphrase: "secret")
        #expect(throws: (any Error).self) { try cipher.open(Wire.encode(.hello)) }
        #expect(throws: (any Error).self) { try cipher.open(Data([0x41, 0x53, 0x59, 0x45, 1, 2, 3])) }
        #expect(throws: (any Error).self) { try cipher.open(Data()) }
    }
}
