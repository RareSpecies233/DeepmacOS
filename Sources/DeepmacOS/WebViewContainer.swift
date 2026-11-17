import AppKit
import SwiftUI
import WebKit

struct WebViewContainer: NSViewRepresentable {
    let model: AppModel

    func makeCoordinator() -> WebCoordinator {
        WebCoordinator(model: model)
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.preferences.isElementFullscreenEnabled = true
        config.defaultWebpagePreferences.allowsContentJavaScript = true

        let controller = WKUserContentController()
        controller.add(context.coordinator, name: "deepmacos")
        controller.addUserScript(WKUserScript(
            source: "window.__deepmacos = { version: '0.1.0' };",
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
        config.userContentController = controller

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = false
        webView.setValue(false, forKey: "drawsBackground")

        model.attach(webView: webView)
        if let url = model.serverURL {
            webView.load(URLRequest(url: url))
        }
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        if webView.url == nil, let url = model.serverURL {
            webView.load(URLRequest(url: url))
        }
    }
}

final class WebCoordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler, WKDownloadDelegate {
    private weak var model: AppModel?

    init(model: AppModel) {
        self.model = model
    }

    // MARK: - 导航策略

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }
        if navigationAction.shouldPerformDownload {
            decisionHandler(.download)
            return
        }
        // 应用内页面（回环服务 + blob）
        if let host = url.host, host == "127.0.0.1" || host == "localhost" {
            decisionHandler(.allow)
            return
        }
        if url.scheme == "blob" || url.scheme == "data" || url.scheme == "about" {
            decisionHandler(.allow)
            return
        }
        // 外部链接交给系统浏览器
        if let scheme = url.scheme?.lowercased(), ["http", "https", "mailto"].contains(scheme) || scheme == "file" {
            decisionHandler(.cancel)
            if scheme == "http" || scheme == "https" || scheme == "mailto" {
                NSWorkspace.shared.open(url)
            }
            return
        }
        decisionHandler(.cancel)
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if !navigationResponse.canShowMIMEType {
            decisionHandler(.download)
        } else {
            decisionHandler(.allow)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        NSLog("DeepmacOS navigation finished: %@", webView.url?.absoluteString ?? "?")
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        NSLog("DeepmacOS navigation failed: %@", error.localizedDescription)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        NSLog("DeepmacOS provisional navigation failed: %@", error.localizedDescription)
    }

    // MARK: - 新窗口 / 文件选择 / 麦克风

    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url, let scheme = url.scheme?.lowercased(),
           scheme == "http" || scheme == "https" {
            NSWorkspace.shared.open(url)
        }
        return nil
    }

    func webView(_ webView: WKWebView,
                 runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        panel.begin { response in
            completionHandler(response == .OK ? panel.urls : nil)
        }
    }

    func webView(_ webView: WKWebView,
                 requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo,
                 type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        // 只放行麦克风（语音输入），摄像头与屏幕录制一律拒绝
        decisionHandler(type == .microphone ? .grant : .deny)
    }

    // MARK: - 下载

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    func download(_ download: WKDownload,
                  decideDestinationUsing response: URLResponse,
                  suggestedFilename: String) async -> URL? {
        if let directory = ProcessInfo.processInfo.environment["DEEPMACOS_SELFTEST_DOWNLOAD_DIR"] {
            let url = URL(fileURLWithPath: directory).appendingPathComponent(
                suggestedFilename.isEmpty ? "deepmacos-selftest.zip" : suggestedFilename
            )
            try? FileManager.default.removeItem(at: url)
            NSLog("DeepmacOS selftest: download destination %@", url.path)
            return url
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedFilename.isEmpty ? "deepmacos-export.zip" : suggestedFilename
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url
    }

    func downloadDidFinish(_ download: WKDownload) {
        NSLog("DeepmacOS download finished")
        model?.notifyDownloadFinished()
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        model?.notifyDownloadFailed(error.localizedDescription)
    }

    // MARK: - 页面桥接

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        model?.handleBridge(body)
    }
}
