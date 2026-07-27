import Foundation
import IOKit

// The AppleSMC transport in this root-only helper is adapted from SMCKit in
// Alexander Goodkind's macos-smc-fan research project (MIT License, 2026).
// Sleep Switch intentionally exposes no raw read or write operation over XPC.

enum SMCReadError: Error, LocalizedError {
    case unavailable
    case invalidKey
    case invalidDataSize(UInt32)
    case ioKit(Int32)
    case firmware(UInt8)
    case writeSizeMismatch
    case unsupportedDataType(String)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "Apple SMC telemetry is unavailable."
        case .invalidKey:
            return "The SMC key is invalid."
        case .invalidDataSize(let size):
            return "The SMC value has an invalid size (\(size))."
        case .ioKit(let code):
            return "IOKit could not read SMC telemetry (0x\(String(UInt32(bitPattern: code), radix: 16)))."
        case .firmware(let code):
            return "The SMC rejected a telemetry read (0x\(String(code, radix: 16)))."
        case .writeSizeMismatch:
            return "The SMC value size changed before it could be written."
        case .unsupportedDataType(let dataType):
            return "The SMC data type \(dataType) is not supported."
        }
    }
}

struct SMCReadValue: Equatable {
    let key: String
    let dataType: String
    let bytes: [UInt8]

    var doubleValue: Double? {
        switch dataType {
        case "ui8 ":
            guard let first = bytes.first else { return nil }
            return Double(first)
        case "ui16":
            guard bytes.count >= 2 else { return nil }
            return Double(uint16)
        case "ui32":
            guard bytes.count >= 4 else { return nil }
            return Double(uint32)
        case "flt ":
            guard bytes.count >= 4 else { return nil }
            let value = bytes.withUnsafeBytes {
                $0.loadUnaligned(as: Float.self)
            }
            return value.isFinite ? Double(value) : nil
        case "fpe2":
            guard bytes.count >= 2 else { return nil }
            return Double(uint16) / 4
        case "sp1e":
            return signedFixedPoint(fractionalBits: 14)
        case "sp3c":
            return signedFixedPoint(fractionalBits: 12)
        case "sp4b":
            return signedFixedPoint(fractionalBits: 11)
        case "sp5a":
            return signedFixedPoint(fractionalBits: 10)
        case "sp69":
            return signedFixedPoint(fractionalBits: 9)
        case "sp78":
            return signedFixedPoint(fractionalBits: 8)
        case "sp87":
            return signedFixedPoint(fractionalBits: 7)
        case "sp96":
            return signedFixedPoint(fractionalBits: 6)
        case "spa5":
            return signedFixedPoint(fractionalBits: 5)
        case "spb4":
            return signedFixedPoint(fractionalBits: 4)
        case "spf0":
            return signedFixedPoint(fractionalBits: 0)
        default:
            return nil
        }
    }

    func bytes(encodingRPM rpm: Double) throws -> [UInt8] {
        guard rpm.isFinite, rpm >= 0, rpm <= 20_000 else {
            throw SMCReadError.unsupportedDataType(dataType)
        }

        switch dataType {
        case "flt ":
            guard bytes.count == 4 else {
                throw SMCReadError.writeSizeMismatch
            }
            var value = Float(rpm)
            return withUnsafeBytes(of: &value) { Array($0) }
        case "fpe2":
            guard bytes.count == 2 else {
                throw SMCReadError.writeSizeMismatch
            }
            let scaled = (rpm * 4).rounded()
            guard scaled <= Double(UInt16.max) else {
                throw SMCReadError.unsupportedDataType(dataType)
            }
            let raw = UInt16(scaled)
            return [UInt8(raw >> 8), UInt8(raw & 0xff)]
        default:
            throw SMCReadError.unsupportedDataType(dataType)
        }
    }

    private var uint16: UInt16 {
        UInt16(bytes[0]) << 8 | UInt16(bytes[1])
    }

    private var uint32: UInt32 {
        UInt32(bytes[0]) << 24
            | UInt32(bytes[1]) << 16
            | UInt32(bytes[2]) << 8
            | UInt32(bytes[3])
    }

    private func signedFixedPoint(fractionalBits: Int) -> Double? {
        guard bytes.count >= 2 else { return nil }
        let raw = Int16(bitPattern: uint16)
        return Double(raw) / Double(1 << fractionalBits)
    }
}

protocol SMCValueReading {
    func readValue(forKey key: String) throws -> SMCReadValue?
}

protocol SMCControlling: SMCValueReading {
    func writeValue(forKey key: String, bytes: [UInt8]) throws
}

private enum SMCReadCommand: UInt8 {
    case kernelIndex = 2
    case readBytes = 5
    case writeBytes = 6
    case readKeyInfo = 9
}

private struct SMCReadParam {
    typealias Bytes32 = (
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
    )

    struct Version {
        var major: UInt8 = 0
        var minor: UInt8 = 0
        var build: UInt8 = 0
        var reserved: UInt8 = 0
        var release: UInt16 = 0
    }

    struct PLimitData {
        var version: UInt16 = 0
        var length: UInt16 = 0
        var cpuPLimit: UInt32 = 0
        var gpuPLimit: UInt32 = 0
        var memPLimit: UInt32 = 0
    }

    struct KeyInfo {
        var dataSize: UInt32 = 0
        var dataType: UInt32 = 0
        var dataAttributes: UInt8 = 0
    }

    var key: UInt32 = 0
    var vers = Version()
    var pLimitData = PLimitData()
    var keyInfo = KeyInfo()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: Bytes32 = (
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0
    )
}

final class SMCConnection: SMCControlling {
    private let connection: io_connect_t

    init() throws {
        var iterator: io_iterator_t = 0
        let matchResult = IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("AppleSMC"),
            &iterator
        )
        guard matchResult == kIOReturnSuccess else {
            throw SMCReadError.ioKit(matchResult)
        }
        defer { IOObjectRelease(iterator) }

        let service = IOIteratorNext(iterator)
        guard service != 0 else {
            throw SMCReadError.unavailable
        }
        defer { IOObjectRelease(service) }

        var openedConnection: io_connect_t = 0
        let openResult = IOServiceOpen(
            service,
            mach_task_self_,
            0,
            &openedConnection
        )
        guard openResult == kIOReturnSuccess else {
            throw SMCReadError.ioKit(openResult)
        }
        connection = openedConnection
    }

    deinit {
        IOServiceClose(connection)
    }

    func readValue(forKey key: String) throws -> SMCReadValue? {
        var keyInfoInput = SMCReadParam()
        keyInfoInput.key = try fourCharacterCode(key)
        keyInfoInput.data8 = SMCReadCommand.readKeyInfo.rawValue
        let keyInfoOutput = try call(keyInfoInput)

        if keyInfoOutput.result == 0x84 {
            return nil
        }
        guard keyInfoOutput.result == 0 else {
            throw SMCReadError.firmware(keyInfoOutput.result)
        }

        let size = keyInfoOutput.keyInfo.dataSize
        guard size > 0, size <= 32 else {
            throw SMCReadError.invalidDataSize(size)
        }

        var readInput = SMCReadParam()
        readInput.key = keyInfoInput.key
        readInput.keyInfo.dataSize = size
        readInput.data8 = SMCReadCommand.readBytes.rawValue
        let readOutput = try call(readInput)
        guard readOutput.result == 0 else {
            throw SMCReadError.firmware(readOutput.result)
        }

        let bytes = withUnsafeBytes(of: readOutput.bytes) {
            Array($0.prefix(Int(size)))
        }
        return SMCReadValue(
            key: key,
            dataType: fourCharacterString(keyInfoOutput.keyInfo.dataType),
            bytes: bytes
        )
    }

    func writeValue(forKey key: String, bytes: [UInt8]) throws {
        guard let currentValue = try readValue(forKey: key) else {
            throw SMCReadError.firmware(0x84)
        }
        guard bytes.count == currentValue.bytes.count,
              !bytes.isEmpty,
              bytes.count <= 32
        else {
            throw SMCReadError.writeSizeMismatch
        }

        var input = SMCReadParam()
        input.key = try fourCharacterCode(key)
        input.data8 = SMCReadCommand.writeBytes.rawValue
        input.keyInfo.dataSize = UInt32(bytes.count)
        input.bytes = bytesTuple(bytes)
        let output = try call(input)
        guard output.result == 0 else {
            throw SMCReadError.firmware(output.result)
        }
    }

    static func hardwareModel() -> String {
        hardwareModelIdentifier()
    }

    private func call(_ input: SMCReadParam) throws -> SMCReadParam {
        var input = input
        var output = SMCReadParam()
        var outputSize = MemoryLayout<SMCReadParam>.stride

        let result = IOConnectCallStructMethod(
            connection,
            UInt32(SMCReadCommand.kernelIndex.rawValue),
            &input,
            MemoryLayout<SMCReadParam>.stride,
            &output,
            &outputSize
        )
        guard result == kIOReturnSuccess else {
            throw SMCReadError.ioKit(result)
        }
        return output
    }

    private func fourCharacterCode(_ key: String) throws -> UInt32 {
        guard key.utf8.count == 4 else {
            throw SMCReadError.invalidKey
        }
        return key.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    private func fourCharacterString(_ code: UInt32) -> String {
        let bytes = [
            UInt8((code >> 24) & 0xff),
            UInt8((code >> 16) & 0xff),
            UInt8((code >> 8) & 0xff),
            UInt8(code & 0xff)
        ]
        return String(bytes: bytes, encoding: .ascii) ?? "????"
    }

    private func bytesTuple(_ source: [UInt8]) -> SMCReadParam.Bytes32 {
        let bytes = source + Array(
            repeating: 0,
            count: max(0, 32 - source.count)
        )
        return (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15],
            bytes[16], bytes[17], bytes[18], bytes[19],
            bytes[20], bytes[21], bytes[22], bytes[23],
            bytes[24], bytes[25], bytes[26], bytes[27],
            bytes[28], bytes[29], bytes[30], bytes[31]
        )
    }
}

private func hardwareModelIdentifier() -> String {
    var size = 0
    guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else {
        return "Unknown"
    }
    var bytes = [CChar](repeating: 0, count: size)
    guard sysctlbyname("hw.model", &bytes, &size, nil, 0) == 0 else {
        return "Unknown"
    }
    return String(
        bytes: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
        encoding: .utf8
    ) ?? "Unknown"
}
