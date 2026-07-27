enum AppDistribution {
#if APP_STORE
    static let isAppStoreBuild = true
    static let supportsGlobalAgentTracking = false
    static let supportsDisplaySleep = false
    static let supportsLidClosedAwake = false
    static let supportsFanControl = false
#else
    static let isAppStoreBuild = false
    static let supportsGlobalAgentTracking = true
    static let supportsDisplaySleep = true
    static let supportsLidClosedAwake = true
    static let supportsFanControl = true
#endif
}
