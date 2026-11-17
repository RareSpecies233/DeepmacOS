import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    private var window: NSWindow?
    private var settingsWindow: NSWindow?
    private var usageWindow: NSWindow?
    private var statusItem: NSStatusItem?
    private var hotKey: GlobalHotKey?
    private var cancellables = Set<AnyCancellable>()

    // MARK: - 生命周期

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        buildMainWindow()
        model.start()
        syncEnhancements()
        observePreferences()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showMainWindow() }
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        model.clearBadge()
        model.refreshBalance()
        // 通知权限放到用户真正激活应用时再请求，避免后台任务弹系统提示
        Notifier.shared.requestAuthorization()
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotKey?.unregister()
        hotKey = nil
    }

    // MARK: - 窗口

    private func buildMainWindow() {
        let controller = NSHostingController(rootView: ContentView(model: model))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        window.title = "DeepmacOS"
        window.titlebarAppearsTransparent = false
        window.minSize = NSSize(width: 760, height: 520)
        // 赋值 contentViewController 会按视图 fitting size 收缩窗口，这里显式撑开
        window.setContentSize(NSSize(width: 1180, height: 800))

        // 恢复上次位置，但必须落在可见区域内，否则重新居中
        let autosaveName = "DeepmacOS.MainWindow"
        var restored = window.setFrameUsingName(autosaveName)
        if restored, let screen = NSScreen.main {
            let visible = screen.visibleFrame
            let frame = window.frame
            restored = visible.intersects(frame)
                && frame.width >= 760 && frame.height >= 520
                && visible.contains(NSPoint(x: frame.midX, y: frame.midY))
        }
        if !restored {
            window.center()
        }
        window.setFrameAutosaveName(autosaveName)
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }

    @objc func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        model.focusComposer()
    }

    @objc func toggleMainWindow() {
        if let window, window.isVisible, window.isKeyWindow {
            window.orderOut(nil)
            return
        }
        showMainWindow()
    }

    @objc func showSettings() {
        if settingsWindow == nil {
            let controller = NSHostingController(rootView: SettingsRootView(model: model))
            let newWindow = NSWindow(contentViewController: controller)
            newWindow.title = "设置"
            newWindow.styleMask = [.titled, .closable]
            newWindow.isReleasedWhenClosed = false
            newWindow.center()
            settingsWindow = newWindow
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
        model.refreshBalance()
    }

    @objc func showUsage() {
        if usageWindow == nil {
            let controller = NSHostingController(rootView: UsagePanel(model: model))
            let newWindow = NSWindow(contentViewController: controller)
            newWindow.title = "用量与费用"
            newWindow.styleMask = [.titled, .closable, .resizable]
            newWindow.setContentSize(NSSize(width: 620, height: 680))
            newWindow.isReleasedWhenClosed = false
            newWindow.center()
            usageWindow = newWindow
        }
        NSApp.activate(ignoringOtherApps: true)
        usageWindow?.makeKeyAndOrderFront(nil)
        model.refreshBalance(force: true)
    }

    // MARK: - 动作

    @objc func newChat() {
        showMainWindow()
        model.newChat()
    }

    @objc func reloadPage() {
        model.reload()
    }

    @objc func showFind() {
        model.toggleFindBar()
    }

    @objc func zoomIn() {
        model.zoom(delta: 0.1)
    }

    @objc func zoomOut() {
        model.zoom(delta: -0.1)
    }

    @objc func zoomReset() {
        model.resetZoom()
    }

    @objc func selfTestProbe() {
        model.probePage()
    }

    @objc func selfTestKey() {
        model.applySelftestKey()
    }

    @objc func selfTestSend() {
        model.sendSelftestMessage()
    }

    @objc func selfTestUsage() {
        model.injectSyntheticUsage()
    }

    @objc func selfTestDownload() {
        model.runDownloadTest()
    }

    @objc func openDocs() {
        if let url = URL(string: "https://api-docs.deepseek.com/") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - 菜单

    private func menuItem(
        _ title: String,
        _ action: Selector?,
        _ key: String = "",
        _ modifiers: NSEvent.ModifierFlags = .command
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = self
        return item
    }

    private func buildMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(
            withTitle: "关于 DeepmacOS",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        appMenu.addItem(.separator())
        appMenu.addItem(menuItem("设置…", #selector(showSettings), ","))
        appMenu.addItem(menuItem("用量与费用…", #selector(showUsage), "u", [.command, .shift]))
        appMenu.addItem(.separator())

        let servicesItem = NSMenuItem(title: "服务", action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu()
        servicesItem.submenu = servicesMenu
        NSApp.servicesMenu = servicesMenu
        appMenu.addItem(servicesItem)

        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "隐藏 DeepmacOS",
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"
        )
        let hideOthers = NSMenuItem(
            title: "隐藏其他",
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h"
        )
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthers)
        appMenu.addItem(
            withTitle: "显示全部",
            action: #selector(NSApplication.unhideAllApplications(_:)),
            keyEquivalent: ""
        )
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "退出 DeepmacOS",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )

        // 文件
        let fileItem = NSMenuItem()
        main.addItem(fileItem)
        let fileMenu = NSMenu(title: "文件")
        fileItem.submenu = fileMenu
        fileMenu.addItem(menuItem("新建对话", #selector(newChat), "n"))
        fileMenu.addItem(menuItem("重新载入", #selector(reloadPage), "r"))
        fileMenu.addItem(.separator())
        fileMenu.addItem(
            withTitle: "关闭窗口",
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w"
        )

        // 编辑（标准响应链选择器，保证 WebView 里的复制粘贴可用）
        let editItem = NSMenuItem()
        main.addItem(editItem)
        let editMenu = NSMenu(title: "编辑")
        editItem.submenu = editMenu
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = NSMenuItem(title: "重做", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redo)
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(.separator())
        editMenu.addItem(menuItem("查找…", #selector(showFind), "f"))

        // 显示
        let viewItem = NSMenuItem()
        main.addItem(viewItem)
        let viewMenu = NSMenu(title: "显示")
        viewItem.submenu = viewMenu
        viewMenu.addItem(menuItem("放大", #selector(zoomIn), "+"))
        viewMenu.addItem(menuItem("缩小", #selector(zoomOut), "-"))
        viewMenu.addItem(menuItem("实际大小", #selector(zoomReset), "0"))
        viewMenu.addItem(.separator())
        viewMenu.addItem(
            withTitle: "进入全屏",
            action: #selector(NSWindow.toggleFullScreen(_:)),
            keyEquivalent: "f"
        ).keyEquivalentModifierMask = [.command, .control]

        // 窗口
        let windowItem = NSMenuItem()
        main.addItem(windowItem)
        let windowMenu = NSMenu(title: "窗口")
        windowItem.submenu = windowMenu
        windowMenu.addItem(
            withTitle: "最小化",
            action: #selector(NSWindow.performMiniaturize(_:)),
            keyEquivalent: "m"
        )
        windowMenu.addItem(withTitle: "缩放", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(
            withTitle: "前置全部窗口",
            action: #selector(NSApplication.arrangeInFront(_:)),
            keyEquivalent: ""
        )
        NSApp.windowsMenu = windowMenu

        if ProcessInfo.processInfo.environment["DEEPMACOS_SELFTEST"] == "1" {
            let testItem = NSMenuItem()
            main.addItem(testItem)
            let testMenu = NSMenu(title: "自检")
            testItem.submenu = testMenu
            testMenu.addItem(menuItem("页面探针", #selector(selfTestProbe), ""))
            testMenu.addItem(menuItem("写入 API Key（env）", #selector(selfTestKey), ""))
            testMenu.addItem(menuItem("发送测试消息", #selector(selfTestSend), ""))
            testMenu.addItem(menuItem("合成一次用量事件", #selector(selfTestUsage), ""))
            testMenu.addItem(menuItem("触发 blob 下载", #selector(selfTestDownload), ""))
        }

        // 帮助
        let helpItem = NSMenuItem()
        main.addItem(helpItem)
        let helpMenu = NSMenu(title: "帮助")
        helpItem.submenu = helpMenu
        helpMenu.addItem(menuItem("DeepSeek API 文档", #selector(openDocs), ""))

        NSApp.mainMenu = main
    }

    // MARK: - 增强功能（默认全部关闭）

    private func observePreferences() {
        model.prefs.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    self?.syncEnhancements()
                }
            }
            .store(in: &cancellables)
    }

    private func syncEnhancements() {
        if model.prefs.globalHotKeyEnabled {
            if hotKey == nil { hotKey = GlobalHotKey() }
            if hotKey?.isRegistered == false {
                hotKey?.register { [weak self] in
                    self?.toggleMainWindow()
                }
            }
        } else {
            hotKey?.unregister()
            hotKey = nil
        }

        if model.prefs.menuBarEnabled {
            installStatusItem()
        } else {
            removeStatusItem()
        }
    }

    private func installStatusItem() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(
            systemSymbolName: "text.bubble",
            accessibilityDescription: "DeepmacOS"
        )
        let menu = NSMenu()
        let show = NSMenuItem(title: "显示窗口", action: #selector(showMainWindow), keyEquivalent: "")
        show.target = self
        menu.addItem(show)
        let newChat = NSMenuItem(title: "新建对话", action: #selector(self.newChat), keyEquivalent: "")
        newChat.target = self
        menu.addItem(newChat)
        let usage = NSMenuItem(title: "用量与费用…", action: #selector(showUsage), keyEquivalent: "")
        usage.target = self
        menu.addItem(usage)
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "退出",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: ""
        )
        item.menu = menu
        statusItem = item
    }

    private func removeStatusItem() {
        guard let statusItem else { return }
        NSStatusBar.system.removeStatusItem(statusItem)
        self.statusItem = nil
    }

    // MARK: - Services（默认不动作）

    @objc func askDeepSeek(
        _ pboard: NSPasteboard,
        userData: String,
        error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        guard model.prefs.servicesEnabled else {
            error.pointee = "该功能未启用：请在 DeepmacOS 设置 → 通用 → 增强功能中开启" as NSString
            NSSound.beep()
            return
        }
        guard let text = pboard.string(forType: .string), !text.isEmpty else {
            error.pointee = "没有可用的文本" as NSString
            return
        }
        showMainWindow()
        model.fillComposer(text)
    }
}
