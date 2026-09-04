import CryptoKit
import Foundation

/// The cryptographic boundary for a future explicit local-preview relay.
///
/// A preview registration is never inferred from a development server. When a
/// Mac owner registers one, the paired companion receives this small, private
/// record through the existing iCloud path. It contains no project name,
/// localhost URL, prompt, or file path. The capability secret authenticates
/// the paired iPhone/iPad; the static public key authenticates the Mac; a new
/// ephemeral client key gives each connection its own encryption key.
///
/// This is deliberately transport-agnostic. Network/Bonjour code must use
/// these handshakes before it ever proxies bytes to a registered loopback
/// endpoint. A plain HTTP relay, or a bearer token sent as a URL, is not an
/// acceptable substitute.
struct LocalPreviewRegistration: Codable, Equatable, Identifiable {
    static let protocolVersion = 1
    static let capabilityByteCount = 32
    static let nonceByteCount = 32
    static let servicePrefix = "ss-preview-"

    let id: UUID
    /// An opaque Bonjour name; it is intentionally unrelated to an upstream
    /// port, project, hostname, or user-visible task title.
    let serviceID: String
    let expiresAt: Date
    let macPublicKey: Data
    let capabilitySecret: Data

    var isExpired: Bool { expiresAt <= Date() }

    static func begin(
        id: UUID = UUID(),
        now: Date = Date(),
        lifetime: TimeInterval = 15 * 60
    ) -> (registration: LocalPreviewRegistration, privateKey: Curve25519.KeyAgreement.PrivateKey) {
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        let capabilitySecret = Data((0..<capabilityByteCount).map { _ in UInt8.random(in: .min ... .max) })
        let opaqueID = Data((0..<12).map { _ in UInt8.random(in: .min ... .max) })
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
            .lowercased()

        return (
            LocalPreviewRegistration(
                id: id,
                serviceID: servicePrefix + opaqueID,
                expiresAt: now.addingTimeInterval(lifetime),
                macPublicKey: privateKey.publicKey.rawRepresentation,
                capabilitySecret: capabilitySecret
            ),
            privateKey
        )
    }
}

enum LocalPreviewSecurityError: Error, Equatable {
    case expiredRegistration
    case malformedKey
    case malformedNonce
    case authenticationFailed
    case encryptionFailed
}

/// A compact, fixed-shape handshake for the local preview channel. All fields
/// are binary-safe Codable `Data`; callers should frame them as a length-bound
/// message over a Network.framework connection rather than turn them into URLs
/// or Bonjour TXT records.
struct LocalPreviewClientHello: Codable, Equatable {
    let registrationID: UUID
    let clientPublicKey: Data
    let clientNonce: Data
    let proof: Data
}

struct LocalPreviewServerHello: Codable, Equatable {
    let serverNonce: Data
    let proof: Data
}

enum LocalPreviewSecurity {
    private static let clientLabel = Data("Sleep Switch Preview Client v1".utf8)
    private static let serverLabel = Data("Sleep Switch Preview Server v1".utf8)
    private static let sessionLabel = Data("Sleep Switch Preview Session v1".utf8)

    static func makeClientHello(
        registration: LocalPreviewRegistration,
        clientPrivateKey: Curve25519.KeyAgreement.PrivateKey = .init(),
        clientNonce: Data = randomNonce()
    ) throws -> (hello: LocalPreviewClientHello, privateKey: Curve25519.KeyAgreement.PrivateKey) {
        try validate(registration: registration, nonce: clientNonce)
        let publicKey = clientPrivateKey.publicKey.rawRepresentation
        let proof = authenticationCode(
            label: clientLabel,
            registration: registration,
            clientPublicKey: publicKey,
            clientNonce: clientNonce
        )
        return (
            LocalPreviewClientHello(
                registrationID: registration.id,
                clientPublicKey: publicKey,
                clientNonce: clientNonce,
                proof: proof
            ),
            clientPrivateKey
        )
    }

    static func acceptClientHello(
        _ hello: LocalPreviewClientHello,
        registration: LocalPreviewRegistration,
        macPrivateKey: Curve25519.KeyAgreement.PrivateKey,
        serverNonce: Data = randomNonce()
    ) throws -> (hello: LocalPreviewServerHello, sessionKey: SymmetricKey) {
        try validate(registration: registration, nonce: hello.clientNonce)
        guard hello.registrationID == registration.id,
              hello.proof == authenticationCode(
                label: clientLabel,
                registration: registration,
                clientPublicKey: hello.clientPublicKey,
                clientNonce: hello.clientNonce
              ) else {
            throw LocalPreviewSecurityError.authenticationFailed
        }
        guard macPrivateKey.publicKey.rawRepresentation == registration.macPublicKey else {
            throw LocalPreviewSecurityError.authenticationFailed
        }
        guard serverNonce.count == LocalPreviewRegistration.nonceByteCount else {
            throw LocalPreviewSecurityError.malformedNonce
        }
        let clientPublicKey = try key(from: hello.clientPublicKey)
        let sessionKey = try sessionKey(
            localPrivateKey: macPrivateKey,
            remotePublicKey: clientPublicKey,
            registration: registration,
            clientNonce: hello.clientNonce,
            serverNonce: serverNonce
        )
        let proof = authenticationCode(
            label: serverLabel,
            registration: registration,
            clientPublicKey: hello.clientPublicKey,
            clientNonce: hello.clientNonce,
            serverNonce: serverNonce
        )
        return (LocalPreviewServerHello(serverNonce: serverNonce, proof: proof), sessionKey)
    }

    static func acceptServerHello(
        _ hello: LocalPreviewServerHello,
        registration: LocalPreviewRegistration,
        clientPrivateKey: Curve25519.KeyAgreement.PrivateKey,
        clientHello: LocalPreviewClientHello
    ) throws -> SymmetricKey {
        try validate(registration: registration, nonce: clientHello.clientNonce)
        guard hello.serverNonce.count == LocalPreviewRegistration.nonceByteCount else {
            throw LocalPreviewSecurityError.malformedNonce
        }
        guard hello.proof == authenticationCode(
            label: serverLabel,
            registration: registration,
            clientPublicKey: clientHello.clientPublicKey,
            clientNonce: clientHello.clientNonce,
            serverNonce: hello.serverNonce
        ) else {
            throw LocalPreviewSecurityError.authenticationFailed
        }
        return try sessionKey(
            localPrivateKey: clientPrivateKey,
            remotePublicKey: key(from: registration.macPublicKey),
            registration: registration,
            clientNonce: clientHello.clientNonce,
            serverNonce: hello.serverNonce
        )
    }

    static func seal(_ payload: Data, using key: SymmetricKey) throws -> Data {
        do {
            return try AES.GCM.seal(payload, using: key).combined ?? { throw LocalPreviewSecurityError.encryptionFailed }()
        } catch let error as LocalPreviewSecurityError {
            throw error
        } catch {
            throw LocalPreviewSecurityError.encryptionFailed
        }
    }

    static func open(_ encryptedPayload: Data, using key: SymmetricKey) throws -> Data {
        do {
            let box = try AES.GCM.SealedBox(combined: encryptedPayload)
            return try AES.GCM.open(box, using: key)
        } catch {
            throw LocalPreviewSecurityError.encryptionFailed
        }
    }

    static func randomNonce() -> Data {
        Data((0..<LocalPreviewRegistration.nonceByteCount).map { _ in UInt8.random(in: .min ... .max) })
    }

    private static func validate(registration: LocalPreviewRegistration, nonce: Data) throws {
        guard !registration.isExpired else { throw LocalPreviewSecurityError.expiredRegistration }
        guard registration.capabilitySecret.count == LocalPreviewRegistration.capabilityByteCount,
              registration.macPublicKey.count == 32 else {
            throw LocalPreviewSecurityError.malformedKey
        }
        guard nonce.count == LocalPreviewRegistration.nonceByteCount else {
            throw LocalPreviewSecurityError.malformedNonce
        }
    }

    private static func key(from data: Data) throws -> Curve25519.KeyAgreement.PublicKey {
        do {
            return try Curve25519.KeyAgreement.PublicKey(rawRepresentation: data)
        } catch {
            throw LocalPreviewSecurityError.malformedKey
        }
    }

    private static func authenticationCode(
        label: Data,
        registration: LocalPreviewRegistration,
        clientPublicKey: Data,
        clientNonce: Data,
        serverNonce: Data = Data()
    ) -> Data {
        let payload = label
            + Data(registration.id.uuidString.utf8)
            + Data(registration.serviceID.utf8)
            + registration.macPublicKey
            + clientPublicKey
            + clientNonce
            + serverNonce
        return Data(HMAC<SHA256>.authenticationCode(for: payload, using: SymmetricKey(data: registration.capabilitySecret)))
    }

    private static func sessionKey(
        localPrivateKey: Curve25519.KeyAgreement.PrivateKey,
        remotePublicKey: Curve25519.KeyAgreement.PublicKey,
        registration: LocalPreviewRegistration,
        clientNonce: Data,
        serverNonce: Data
    ) throws -> SymmetricKey {
        do {
            let secret = try localPrivateKey.sharedSecretFromKeyAgreement(with: remotePublicKey)
            let salt = registration.capabilitySecret + clientNonce + serverNonce
            return secret.hkdfDerivedSymmetricKey(
                using: SHA256.self,
                salt: salt,
                sharedInfo: sessionLabel + Data(registration.id.uuidString.utf8),
                outputByteCount: 32
            )
        } catch {
            throw LocalPreviewSecurityError.malformedKey
        }
    }
}
