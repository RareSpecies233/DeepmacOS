import Combine
import Foundation

/// 本机偏好。所有增强功能默认关闭：全局快捷键、Services、菜单栏常驻。
@MainActor
final class Preferences: ObservableObject {
    enum Key {
        static let globalHotKey = "enhance.globalHotKey"
        static let services = "enhance.services"
        static let menuBar = "enhance.menuBar"
        static let threshold = "usage.threshold"
        static let thresholdCurrency = "usage.thresholdCurrency"
        static let notificationsAsked = "privacy.notificationsAsked"
        static let onboardingSeen = "general.onboardingSeen"
        static let webPort = "net.webPort"
    }

    private let defaults: UserDefaults

    @Published var globalHotKeyEnabled: Bool {
        didSet { defaults.set(globalHotKeyEnabled, forKey: Key.globalHotKey) }
    }

    @Published var servicesEnabled: Bool {
        didSet { defaults.set(servicesEnabled, forKey: Key.services) }
    }

    @Published var menuBarEnabled: Bool {
        didSet { defaults.set(menuBarEnabled, forKey: Key.menuBar) }
    }

    /// 低余额提醒阈值，默认 10（配合 thresholdCurrency 使用）
    @Published var lowBalanceThreshold: Double {
        didSet { defaults.set(lowBalanceThreshold, forKey: Key.threshold) }
    }

    @Published var thresholdCurrency: String {
        didSet { defaults.set(thresholdCurrency, forKey: Key.thresholdCurrency) }
    }

    /// 本地服务端口：必须跨启动保持稳定，否则本地存储会按 origin 分裂
    var webPort: UInt16 {
        get { UInt16(clamping: defaults.integer(forKey: Key.webPort)) }
        set { defaults.set(Int(newValue), forKey: Key.webPort) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.globalHotKey: false,
            Key.services: false,
            Key.menuBar: false,
            Key.threshold: 10.0,
            Key.thresholdCurrency: "CNY",
        ])
        globalHotKeyEnabled = defaults.bool(forKey: Key.globalHotKey)
        servicesEnabled = defaults.bool(forKey: Key.services)
        menuBarEnabled = defaults.bool(forKey: Key.menuBar)
        lowBalanceThreshold = defaults.object(forKey: Key.threshold) as? Double ?? 10
        thresholdCurrency = defaults.string(forKey: Key.thresholdCurrency) ?? "CNY"
    }

    var notificationsAsked: Bool {
        get { defaults.bool(forKey: Key.notificationsAsked) }
        set { defaults.set(newValue, forKey: Key.notificationsAsked) }
    }
}
