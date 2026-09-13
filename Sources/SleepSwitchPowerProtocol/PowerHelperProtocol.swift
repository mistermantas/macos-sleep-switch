import Foundation

#if !APP_STORE
enum PowerHelperConstants {
    static let identifier = "lt.mantas.sleepswitch.powerhelper"
    static let plistName = identifier + ".plist"
    static let leaseDuration: TimeInterval = 12
    static let heartbeatInterval: TimeInterval = 3
    static let applicationRequirement = requirement(identifier: "lt.mantas.sleepswitch")
    static let helperRequirement = requirement(identifier: identifier)

    private static func requirement(identifier: String) -> String {
        "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"C43F5MKJF2\""
    }
}

// Only fixed power operations cross this boundary. No commands, paths or
// user-selected settings are accepted by the privileged process.
@objc protocol PowerHelperProtocol {
    func status(withReply reply: @escaping (Bool, String, String) -> Void)
    func beginLease(withReply reply: @escaping (Bool, String, String) -> Void)
    func renewLease(_ token: String, withReply reply: @escaping (Bool, String, String) -> Void)
    func endLease(_ token: String, withReply reply: @escaping (Bool, String, String) -> Void)
}

struct PowerHelperReply {
    var succeeded: Bool
    var token: String = ""
    var message: String = ""
}
#endif
