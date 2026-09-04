import CryptoKit
import Foundation

enum LocalPreviewSecurityTests {
    static func run() {
        let id = UUID(uuidString: "7F5F4585-1A7B-48D5-8968-3D2E94A12419")!
        let macPrivateKey = Curve25519.KeyAgreement.PrivateKey()
        let registration = LocalPreviewRegistration(
            id: id,
            serviceID: "ss-preview-jd7jv9a3zz",
            expiresAt: Date().addingTimeInterval(60),
            macPublicKey: macPrivateKey.publicKey.rawRepresentation,
            capabilitySecret: Data(repeating: 7, count: LocalPreviewRegistration.capabilityByteCount)
        )
        let clientPrivateKey = Curve25519.KeyAgreement.PrivateKey()
        let clientNonce = Data(repeating: 3, count: LocalPreviewRegistration.nonceByteCount)
        let serverNonce = Data(repeating: 4, count: LocalPreviewRegistration.nonceByteCount)

        do {
            let client = try LocalPreviewSecurity.makeClientHello(
                registration: registration,
                clientPrivateKey: clientPrivateKey,
                clientNonce: clientNonce
            )
            let server = try LocalPreviewSecurity.acceptClientHello(
                client.hello,
                registration: registration,
                macPrivateKey: macPrivateKey,
                serverNonce: serverNonce
            )
            let clientKey = try LocalPreviewSecurity.acceptServerHello(
                server.hello,
                registration: registration,
                clientPrivateKey: client.privateKey,
                clientHello: client.hello
            )
            let secret = Data("a bounded preview response".utf8)
            let encrypted = try LocalPreviewSecurity.seal(secret, using: server.sessionKey)
            expect(
                try LocalPreviewSecurity.open(encrypted, using: clientKey) == secret,
                "round-trips a preview payload only after mutual authentication"
            )
        } catch {
            expect(false, "establishes a local preview session: \(error)")
        }

        do {
            let client = try LocalPreviewSecurity.makeClientHello(
                registration: registration,
                clientPrivateKey: clientPrivateKey,
                clientNonce: clientNonce
            )
            let tampered = LocalPreviewClientHello(
                registrationID: client.hello.registrationID,
                clientPublicKey: client.hello.clientPublicKey,
                clientNonce: Data(repeating: 8, count: LocalPreviewRegistration.nonceByteCount),
                proof: client.hello.proof
            )
            _ = try LocalPreviewSecurity.acceptClientHello(
                tampered,
                registration: registration,
                macPrivateKey: macPrivateKey,
                serverNonce: serverNonce
            )
            expect(false, "rejects a tampered preview client handshake")
        } catch LocalPreviewSecurityError.authenticationFailed {
            expect(true, "rejects a tampered preview client handshake")
        } catch {
            expect(false, "rejects tampered preview handshake with authentication failure")
        }

        let expired = LocalPreviewRegistration(
            id: registration.id,
            serviceID: registration.serviceID,
            expiresAt: Date().addingTimeInterval(-1),
            macPublicKey: registration.macPublicKey,
            capabilitySecret: registration.capabilitySecret
        )
        do {
            _ = try LocalPreviewSecurity.makeClientHello(registration: expired)
            expect(false, "refuses an expired preview registration")
        } catch LocalPreviewSecurityError.expiredRegistration {
            expect(true, "refuses an expired preview registration")
        } catch {
            expect(false, "reports expiry distinctly")
        }

        do {
            let first = try LocalPreviewFrame.encode(Data("first".utf8))
            let second = try LocalPreviewFrame.encode(Data("second".utf8))
            var fragmented = Data(first.prefix(5))
            expect(try LocalPreviewFrame.decode(from: &fragmented).isEmpty, "retains an incomplete preview frame")
            fragmented += first.dropFirst(5) + second
            let frames = try LocalPreviewFrame.decode(from: &fragmented)
            expect(frames == [Data("first".utf8), Data("second".utf8)], "decodes bounded preview frames in order")
            expect(fragmented.isEmpty, "consumes complete preview frames")
        } catch {
            expect(false, "frames encrypted preview data: \(error)")
        }
    }
}
