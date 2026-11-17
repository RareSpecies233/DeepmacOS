import AppKit
import Foundation
import UserNotifications

@MainActor
final class Notifier {
    static let shared = Notifier()
    private var requested = false

    /// swift run 时没有 .app 包，UNUserNotificationCenter 会异常，直接跳过
    private var isBundledApp: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    func requestAuthorization() {
        guard isBundledApp, !requested else { return }
        requested = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, error in
            if let error {
                NSLog("DeepmacOS notification authorization failed: \(error.localizedDescription)")
            }
        }
    }

    func completion(title: String) {
        deliver(title: "DeepSeek 回复完成", body: title.isEmpty ? "回到窗口查看结果" : title)
    }

    func lowBalance(currency: String, total: Double, threshold: Double) {
        deliver(
            title: "余额不足提醒",
            body: "当前 \(currency) \(String(format: "%.2f", total))，低于阈值 \(String(format: "%.0f", threshold))"
        )
    }

    func info(title: String, body: String) {
        deliver(title: title, body: body)
    }

    private func deliver(title: String, body: String) {
        guard isBundledApp else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        )
    }
}
