import Foundation
import IOKit

enum CompanionMachineFingerprint {
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
