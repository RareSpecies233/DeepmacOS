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
        let glass = model.usesGlass ? "el.classList.add('deepmacos-glass');" : ""
        let flags = """
        (function () {
          var apply = function () {
            var el = document.documentElement;
            if (!el) return false;
            el.classList.add('deepmacos-titlebar-inset');
            \(glass)
            return true;
          };
          if (!apply()) document.addEventListener('DOMContentLoaded', apply);
        })();
        """
        controller.addUserScript(WKUserScript(
            source: "window.__deepmacos = { version: '0.2.0' };",
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
        controller.addUserScript(WKUserScript(
            source: flags,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
        controller.addUserScript(WKUserScript(
            source: WebCoordinator.dragZonesScript,
            injectionTime: .atDocumentEnd,
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

extension WebCoordinator {
    /// 计算顶栏可拖拽区域（排除按钮），归一化后交给原生做窗口拖动
    static let dragZonesScript = #"""
    (function () {
      if (window.__deepmacosZonesInstalled) { window.__deepmacosCollectZones && window.__deepmacosCollectZones(); return; }
      window.__deepmacosZonesInstalled = true;

      function bands(el) {
        var r = el.getBoundingClientRect();
        if (!r.width || !r.height) return [];
        var holes = Array.prototype.slice.call(el.querySelectorAll('button,[role="button"],a,input,textarea,select'))
          .map(function (b) { return b.getBoundingClientRect(); })
          .filter(function (b) { return b.width > 0 && b.bottom > r.top && b.top < r.bottom; })
          .sort(function (a, b) { return a.left - b.left; });
        var out = [], x = r.left;
        for (var i = 0; i < holes.length; i++) {
          var h = holes[i];
          if (h.left > x) {
            var w = Math.min(h.left, r.right) - x;
            if (w > 4) out.push([x, r.top, w, r.height]);
          }
          x = Math.max(x, h.right);
        }
        if (x < r.right - 1) out.push([x, r.top, r.right - x, r.height]);
        return out;
      }

      function collect() {
        var zones = [];
        var roots = [];
        var siderTop = document.querySelector('[class*="sider"] > [class*="top"]');
        if (siderTop) roots.push(siderTop);
        var viewHeader = document.querySelector('[class*="view"] > [class*="header"]');
        if (viewHeader) roots.push(viewHeader);
        var push = function (x, y, w, h) {
          zones.push({
            x: x / window.innerWidth,
            y: y / window.innerHeight,
            w: w / window.innerWidth,
            h: h / window.innerHeight
          });
        };
        roots.forEach(function (el) {
          bands(el).forEach(function (b) { push(b[0], b[1], b[2], b[3]); });
        });

        // 主区域顶部通用拖拽带（欢迎页没有 header 时也能拖），自动排除按钮
        var sider = document.querySelector('.deepmacos-sider');
        var topBand = 48;
        var startX = sider ? sider.getBoundingClientRect().right : 0;
        var holes = Array.prototype.slice
          .call(document.querySelectorAll('button,[role="button"],a,input,textarea,select'))
          .map(function (b) { return b.getBoundingClientRect(); })
          .filter(function (b) { return b.width > 0 && b.top < topBand && b.bottom > 0 && b.right > startX; })
          .sort(function (a, b) { return a.left - b.left; });
        var cursor = startX;
        holes.forEach(function (h) {
          if (h.left > cursor) push(cursor, 0, Math.min(h.left, window.innerWidth) - cursor, topBand);
          cursor = Math.max(cursor, h.right);
        });
        if (cursor < window.innerWidth - 1) push(cursor, 0, window.innerWidth - cursor, topBand);
        window.__deepmacosZones = zones;
        var avoid = Array.prototype.slice
          .call(document.querySelectorAll('button,[role="button"],a,input,textarea,select,[contenteditable="true"]'))
          .map(function (el) { return el.getBoundingClientRect(); })
          .filter(function (r) { return r.width > 0 && r.height > 0; })
          .map(function (r) {
            return {
              x: r.left / window.innerWidth,
              y: r.top / window.innerHeight,
              w: r.width / window.innerWidth,
              h: r.height / window.innerHeight
            };
          });
        window.__deepmacosAvoid = avoid;
        var headerEl = document.querySelector('[class*="sider"] > [class*="top"]');
        var header = null;
        if (headerEl) {
          var hr = headerEl.getBoundingClientRect();
          header = {
            x: hr.left / window.innerWidth,
            y: hr.top / window.innerHeight,
            w: hr.width / window.innerWidth,
            h: hr.height / window.innerHeight
          };
        }
        try {
          window.webkit.messageHandlers.deepmacos.postMessage({ type: 'dragZones', zones: zones, avoid: avoid, header: header });
        } catch (e) {}
      }

      window.__deepmacosCollectZones = collect;
      requestAnimationFrame(function () { collect(); setTimeout(collect, 400); });
      window.addEventListener('resize', function () { setTimeout(collect, 150); });
      new MutationObserver(function () {
        clearTimeout(window.__deepmacosZoneTimer);
        window.__deepmacosZoneTimer = setTimeout(collect, 250);
      }).observe(document.body, { childList: true, subtree: true });
    })();
    """#
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
        // SPA 重新渲染后刷新拖拽区域，并把桌面状态推给设置页
        webView.evaluateJavaScript("window.__deepmacosCollectZones && window.__deepmacosCollectZones();",
                                   completionHandler: nil)
        if model?.usesGlass == true {
            webView.evaluateJavaScript(
                "document.documentElement.classList.add('deepmacos-titlebar-inset','deepmacos-glass');",
                completionHandler: nil
            )
        }
        model?.sendDesktopState()
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
