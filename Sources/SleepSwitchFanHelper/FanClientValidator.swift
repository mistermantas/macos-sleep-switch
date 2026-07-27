import Foundation
import Security

struct FanClientIdentity: Equatable {
    let signingIdentifier: String
    let teamIdentifier: String
    let certificateCommonName: String
    let hasHardenedRuntime: Bool
    let signatureIsValid: Bool
}

struct FanClientPolicy {
    let expectedSigningIdentifier: String
    let expectedTeamIdentifier: String

    func accepts(_ identity: FanClientIdentity) -> Bool {
        identity.signatureIsValid
            && identity.hasHardenedRuntime
            && identity.signingIdentifier == expectedSigningIdentifier
            && identity.teamIdentifier == expectedTeamIdentifier
            && FanHelperSigningPolicy.acceptsCertificateCommonName(
                identity.certificateCommonName
            )
    }
}

protocol FanClientValidating {
    func accepts(processIdentifier: pid_t) -> Bool
}

struct FanClientValidator: FanClientValidating {
    private let policy = FanClientPolicy(
        expectedSigningIdentifier:
            FanHelperConstants.applicationBundleIdentifier,
        expectedTeamIdentifier: FanHelperConstants.teamIdentifier
    )

    func accepts(processIdentifier: pid_t) -> Bool {
        guard processIdentifier > 0,
              let identity = identity(for: processIdentifier)
        else {
            return false
        }
        return policy.accepts(identity)
    }

    private func identity(for processIdentifier: pid_t) -> FanClientIdentity? {
        let attributes = [
            kSecGuestAttributePid: NSNumber(value: processIdentifier)
        ] as CFDictionary
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(
            nil,
            attributes,
            [],
            &code
        ) == errSecSuccess, let code else {
            return nil
        }

        let validity = SecCodeCheckValidity(
            code,
            SecCSFlags(rawValue: kSecCSStrictValidate),
            nil
        ) == errSecSuccess

        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
              let staticCode
        else {
            return nil
        }

        var signingInformation: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(
            staticCode,
            flags,
            &signingInformation
        ) == errSecSuccess,
        let information = signingInformation as? [String: Any],
        let identifier = information[
            kSecCodeInfoIdentifier as String
        ] as? String,
        let teamIdentifier = information[
            kSecCodeInfoTeamIdentifier as String
        ] as? String,
        let certificates = information[
            kSecCodeInfoCertificates as String
        ] as? [SecCertificate],
        let leafCertificate = certificates.first
        else {
            return nil
        }

        var certificateCommonName: CFString?
        guard SecCertificateCopyCommonName(
            leafCertificate,
            &certificateCommonName
        ) == errSecSuccess,
        let certificateCommonName
        else {
            return nil
        }

        return FanClientIdentity(
            signingIdentifier: identifier,
            teamIdentifier: teamIdentifier,
            certificateCommonName: certificateCommonName as String,
            hasHardenedRuntime:
                information[kSecCodeInfoRuntimeVersion as String] != nil,
            signatureIsValid: validity
        )
    }
}
