import AppKit
import Combine
import Foundation
import WebKit

@MainActor
final class AppModel: ObservableObject {
    let prefs = Preferences()
    let ledger = UsageLedger()

    private var server: LoopbackServer?
    private weak var webView: WKWebView?
    private var lastBalanceAttempt: Date?
    private var lastLowBalanceNotifyDay: String?

    @Published var serverURL: URL?
    @Published var serverError: String?

    @Published var findBarVisible = false
    @Published var findQuery = ""

    @Published var currentTitle = ""

    @Published var balance: [BalanceInfo] = []
    @Published var balanceAvailable: Bool?
    @Published var balanceUpdatedAt: Date?
    @Published var balanceError: String?
    @Published var balanceLoading = false

    // MARK: - 启动

    func start() {
        guard server == nil, serverError == nil else { return }
        guard let root = Self.resolveWebRoot() else {
            serverError = "找不到前端资源（web/），请先执行 make web"
            return
        }
        var candidates: [UInt16] = []
        let saved = prefs.webPort
        if saved >= 1024 { candidates.append(saved) }
        candidates.append(contentsOf: (43_110 ... 43_124).map { UInt16($0) })
        tryPorts(candidates, root: root)
    }

    private func tryPorts(_ ports: [UInt16], root: URL) {
        guard let port = ports.first else {
            serverError = "本机端口都被占用，无法启动本地服务"
            return
        }
        let loopback = LoopbackServer(root: root, port: port, onReady: { [weak self] bound in
            guard let self else { return }
            // 端口写回偏好：下次必须复用同一端口，否则 origin 变化会让本地历史"消失"
            self.prefs.webPort = bound
            let url = URL(string: "http://127.0.0.1:\(bound)/")
            self.serverURL = url
            NSLog("DeepmacOS serving web on %@ (port persisted)", url?.absoluteString ?? "?")
        }, onFailure: { [weak self] in
            guard let self else { return }
            self.server = nil
            self.tryPorts(Array(ports.dropFirst()), root: root)
        })
        guard let loopback else {
            tryPorts(Array(ports.dropFirst()), root: root)
            return
        }
        server = loopback
        loopback.start()
    }

    private static func resolveWebRoot() -> URL? {
        var candidates: [URL] = []
        if let override = ProcessInfo.processInfo.environment["DEEPMACOS_WEB_ROOT"] {
            candidates.append(URL(fileURLWithPath: override))
        }
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appendingPathComponent("web"))
        }
        candidates.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("web"))
        for candidate in candidates where FileManager.default.fileExists(
            atPath: candidate.appendingPathComponent("index.html").path
        ) {
            return candidate
        }
        return nil
    }

    func attach(webView: WKWebView) {
        self.webView = webView
    }

    // MARK: - 页面脚本

    private func jsString(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value]),
              let text = String(data: data, encoding: .utf8) else { return "\"\"" }
        return String(text.dropFirst().dropLast()) // 去掉外层 []，得到 JSON 字符串字面量
    }

    func runJS(_ source: String) {
        webView?.evaluateJavaScript(source, completionHandler: nil)
    }

    func newChat() {
        runJS("""
        (function(){var b=document.querySelector('[class*="newChat"]');if(b){b.click();return true;}return false;})()
        """)
    }

    func focusComposer() {
        runJS("document.querySelector('textarea')?.focus();")
    }

    func fillComposer(_ text: String) {
        let literal = jsString(text)
        runJS("""
        (function(){var t=\(literal);var ta=document.querySelector('textarea');if(!ta){return false;}
        var setter=Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype,'value').set;
        setter.call(ta,t);ta.dispatchEvent(new Event('input',{bubbles:true}));ta.focus();return true;})()
        """)
    }

    func reload() {
        webView?.reload()
    }

    func zoom(delta: Double) {
        guard let webView else { return }
        let next = min(2.0, max(0.5, webView.pageZoom + delta))
        webView.pageZoom = next
    }

    func resetZoom() {
        webView?.pageZoom = 1.0
    }

    func toggleFindBar() {
        findBarVisible.toggle()
        if findBarVisible {
            runJS("document.querySelector('textarea')?.blur();")
        }
    }

    func findNext() {
        let query = findQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        runJS("window.find(\(jsString(query)), false, false, true);")
    }

    // MARK: - 余额

    private func currentAPIKey() async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                guard let webView = self.webView else {
                    continuation.resume(returning: nil)
                    return
                }
                webView.evaluateJavaScript("localStorage.getItem('chat-demo:api-key')") { value, _ in
                    let key = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.resume(returning: (key?.isEmpty ?? true) ? nil : key)
                }
            }
        }
    }

    func refreshBalance(force: Bool = false) {
        guard !balanceLoading else { return }
        if !force, let last = lastBalanceAttempt, Date().timeIntervalSince(last) < 60 { return }
        lastBalanceAttempt = Date()
        balanceLoading = true
        Task { @MainActor in
            defer { self.balanceLoading = false }
            guard let key = await self.currentAPIKey() else {
                self.balance = []
                self.balanceAvailable = nil
                self.balanceError = "还没有设置 API Key（在应用内 设置 → API Key 填写）"
                return
            }
            do {
                let result = try await BalanceClient.fetch(apiKey: key)
                self.balance = result.balance_infos
                self.balanceAvailable = result.is_available
                self.balanceUpdatedAt = Date()
                self.balanceError = nil
                self.checkLowBalance()
            } catch {
                self.balanceError = error.localizedDescription
            }
        }
    }

    private func checkLowBalance() {
        let currency = prefs.thresholdCurrency
        guard let info = balance.first(where: { $0.currency == currency }) else { return }
        let threshold = prefs.lowBalanceThreshold
        guard info.total < threshold else { return }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let today = formatter.string(from: Date())
        guard lastLowBalanceNotifyDay != today else { return }
        lastLowBalanceNotifyDay = today
        Notifier.shared.lowBalance(currency: currency, total: info.total, threshold: threshold)
    }

    // MARK: - 桥接事件

    func handleBridge(_ body: [String: Any]) {
        switch body["type"] as? String {
        case "usage":
            recordUsage(body)
        case "title":
            if let title = body["title"] as? String, !title.isEmpty {
                currentTitle = title
            }
        default:
            break
        }
    }

    private func number(_ value: Any?) -> Int {
        if let int = value as? Int { return int }
        if let double = value as? Double { return Int(double) }
        if let number = value as? NSNumber { return number.intValue }
        return 0
    }

    private func recordUsage(_ body: [String: Any]) {
        let usage = body["usage"] as? [String: Any] ?? [:]
        let tools = usage["server_tool_use"] as? [String: Any] ?? [:]
        let record = UsageRecord(
            t: Date().timeIntervalSince1970,
            model: body["model"] as? String ?? "deepseek-flash",
            input: number(usage["input_tokens"]),
            cacheWrite: number(usage["cache_creation_input_tokens"]),
            cacheRead: number(usage["cache_read_input_tokens"]),
            output: number(usage["output_tokens"]),
            searches: number(tools["web_search_requests"])
        )
        ledger.append(record)

        // 窗口不在前台时提醒，并更新 Dock 角标
        if !NSApp.isActive {
            Notifier.shared.completion(title: currentTitle)
            NSApp.dockTile.badgeLabel = "•"
        }
        refreshBalance()
    }

    func clearBadge() {
        NSApp.dockTile.badgeLabel = nil
    }

    func notifyDownloadFinished() {
        Notifier.shared.info(title: "导出完成", body: "文件已保存到你选择的位置")
    }

    func notifyDownloadFailed(_ message: String) {
        Notifier.shared.info(title: "导出失败", body: message)
    }

    // MARK: - 自检（仅 DEEPMACOS_SELFTEST=1 时通过菜单触发）

    func injectSyntheticUsage() {
        handleBridge([
            "type": "usage",
            "model": "deepseek-flash",
            "usage": [
                "input_tokens": 1_200,
                "cache_creation_input_tokens": 0,
                "cache_read_input_tokens": 800,
                "output_tokens": 350,
                "server_tool_use": ["web_search_requests": 1],
            ],
        ])
        NSLog("DeepmacOS selftest: synthetic usage recorded, total=%d", ledger.records.count)
    }

    func applySelftestKey() {
        guard let key = ProcessInfo.processInfo.environment["DEEPMACOS_SELFTEST_KEY"],
              !key.isEmpty else {
            NSLog("DeepmacOS selftest: DEEPMACOS_SELFTEST_KEY 为空")
            return
        }
        runJS("localStorage.setItem('chat-demo:api-key', \(jsString(key)));")
        NSLog("DeepmacOS selftest: api key written to localStorage")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.reload()
        }
    }

    func sendSelftestMessage() {
        fillComposer("用一句话确认收到，不要展开。")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.runJS("""
            (function(){var ta=document.querySelector('textarea');if(!ta)return false;
            ta.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',bubbles:true,cancelable:true}));return true;})()
            """)
            NSLog("DeepmacOS selftest: message submitted")
        }
    }

    func probePage() {
        // 用异步脚本直接读 IndexedDB，确认本地历史是否真的持久化
        let script = """
        const dbs = (await indexedDB.databases()).map(d => d.name);
        let sessions = -1;
        try {
          const db = await new Promise((resolve, reject) => {
            const req = indexedDB.open('chat-demo');
            req.onsuccess = () => resolve(req.result);
            req.onerror = () => reject(req.error);
          });
          if (db.objectStoreNames.contains('sessionSummaries')) {
            sessions = await new Promise((resolve, reject) => {
              const tx = db.transaction('sessionSummaries', 'readonly');
              const rq = tx.objectStore('sessionSummaries').count();
              rq.onsuccess = () => resolve(rq.result);
              rq.onerror = () => reject(rq.error);
            });
          }
          db.close();
        } catch (e) {
          sessions = -2;
        }
        return {
          title: document.title,
          hasKey: !!localStorage.getItem('chat-demo:api-key'),
          sessions,
          dbs,
          origin: location.origin,
        };
        """
        webView?.callAsyncJavaScript(script, arguments: [:], in: nil, in: .page) { result in
            switch result {
            case let .success(value):
                NSLog("DeepmacOS probe: %@", String(describing: value))
            case let .failure(error):
                NSLog("DeepmacOS probe failed: %@", error.localizedDescription)
            }
        }
    }

    func runDownloadTest() {
        runJS("""
        (function(){var b=new Blob(['deepmacos selftest'],{type:'application/zip'});
        var u=URL.createObjectURL(b);var a=document.createElement('a');a.href=u;
        a.download='deepmacos-selftest.zip';document.body.appendChild(a);a.click();a.remove();return true;})()
        """)
        NSLog("DeepmacOS selftest: blob download triggered")
    }
}
