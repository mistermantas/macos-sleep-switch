import Foundation

struct ExternalFanControllerDetector {
    private let processListing: () -> String?

    init(processListing: @escaping () -> String? = Self.currentProcessListing) {
        self.processListing = processListing
    }

    func isMacsFanControlRunning() -> Bool {
        guard let listing = processListing() else {
            return true
        }
        return Self.containsMacsFanControl(in: listing)
    }

    static func containsMacsFanControl(in processListing: String) -> Bool {
        processListing
            .split(separator: "\n")
            .map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .contains {
                $0 == "Macs Fan Control"
                    || $0.hasSuffix(
                        "/Macs Fan Control.app/Contents/MacOS/Macs Fan Control"
                    )
            }
    }

    private static func currentProcessListing() -> String? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "comm="]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                return nil
            }
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }
}
