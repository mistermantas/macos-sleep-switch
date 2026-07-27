#if !APP_STORE
import Foundation

enum CoolingProfile: String, CaseIterable, Codable {
    case systemControl
    case aggressive
    case maximum

    var menuTitle: String {
        switch self {
        case .systemControl:
            return "System Control"
        case .aggressive:
            return "Aggressive"
        case .maximum:
            return "Maximum"
        }
    }

    var shortDescription: String {
        switch self {
        case .systemControl:
            return "macOS controls the fans"
        case .aggressive:
            return "Ramps early as temperatures rise"
        case .maximum:
            return "Runs every qualified fan at maximum"
        }
    }
}

enum SystemThermalLevel: Int, Comparable, Codable {
    case nominal
    case fair
    case serious
    case critical

    static func < (lhs: SystemThermalLevel, rhs: SystemThermalLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}
#endif
