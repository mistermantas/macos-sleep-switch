import Foundation
import IOKit
import CryptoKit

enum CompanionMachineFingerprint {
    static func stableDeviceID(for fingerprint: String) -> String {
        let normalized = fingerprint.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return "mac-" + SHA256.hash(data: Data(normalized.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    static func deviceID() -> String {
        guard let fingerprint = current(), !fingerprint.isEmpty else {
            return CompanionDeviceIdentity.load(key: "companionMacDeviceID")
        }
        return stableDeviceID(for: fingerprint)
    }

    /// `IOPlatformUUID` is stable for one physical Mac across app versions and
    /// bundle identifiers. We retain it only in the user's private CloudKit
    /// status record to prevent duplicate listings of that same machine.
    static func current() -> String? {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IOPlatformExpertDevice")
        )
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }
        return IORegistryEntryCreateCFProperty(
            service,
            "IOPlatformUUID" as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() as? String
    }
}
