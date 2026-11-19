import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let model = AppModel()

    private var window: NSWindow?
    private var statusItem: NSStatusItem?
    private var hotKey: GlobalHotKey?
    private var cancellables = Set<AnyCancellable>()
    private var mouseMonitor: Any?
    private weak var backdropView: NSVisualEffectView?
    /// 红绿灯矩形（窗口坐标）：点击必须放行，且不能当拖拽区
    private var trafficLightRect: NSRect = .zero
    private var keyMonitor: Any?

    // MARK: - 生命周期

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        buildMainWindow()
        installMouseMonitor()
        installKeyMonitor()
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

    /// 关闭按钮只隐藏窗口，不销毁：单窗口应用再点 Dock 图标即可恢复
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }

    func windowWillStartLiveResize(_ notification: Notification) {
        setBackdropTransient(true)
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        setBackdropTransient(false)
        updateTrafficLightRect()
    }

    func windowDidResize(_ notification: Notification) {
        updateTrafficLightRect()
    }

    /// 拖拽/缩放期间把后景模糊换成普通材质，避免每帧重算导致闪烁
    private func setBackdropTransient(_ transient: Bool) {
        backdropView?.material = transient ? .windowBackground : .underWindowBackground
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotKey?.unregister()
        hotKey = nil
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    }

    // MARK: - 窗口

    private func buildMainWindow() {
        let container = NSView()
        container.wantsLayer = true

        // 底层：真实的窗口后景模糊（采桌面），这是"玻璃感"能透出来的关键
        let backdrop = NSVisualEffectView()
        backdrop.material = .underWindowBackground
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        backdrop.autoresizingMask = [.width, .height]
        backdrop.frame = container.bounds
        container.addSubview(backdrop)

        self.backdropView = backdrop

        let hosting = NSHostingController(rootView: ContentView(model: model))
        hosting.view.frame = container.bounds
        hosting.view.autoresizingMask = [.width, .height]
        container.addSubview(hosting.view)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentView = container
        // 关闭窗口时 AppKit 默认会 release；Swift 的强引用会变成野指针，
        // 再点 Dock 图标（reopen）就会 EXC_BAD_ACCESS。
        window.isReleasedWhenClosed = false
        window.title = "DeepmacOS"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.isMovableByWindowBackground = false
        window.minSize = NSSize(width: 760, height: 520)
        window.setContentSize(NSSize(width: 1180, height: 800))

        // 红绿灯下移，落在原「API 使用 demo」文字的位置
        if let close = window.standardWindowButton(.closeButton), let bar = close.superview {

        }

        // 恢复上次位置，但必须落在可见区域内，否则重新居中
        let autosaveName = "DeepmacOS.MainWindow"
        // 先登记 autosave 再恢复：反过来的话恢复动作会覆盖掉 center()
        window.setFrameAutosaveName(autosaveName)
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
        window.delegate = self
        window.makeKeyAndOrderFront(nil)
        self.window = window

        updateTrafficLightRect()
    }

    private func updateTrafficLightRect() {
        guard let window else { return }
        let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
            .compactMap { window.standardWindowButton($0) }
        guard !buttons.isEmpty else { return }
        let union = buttons
            .map { $0.convert($0.bounds, to: nil) }
            .reduce(NSRect.null) { $0.union($1) }
        trafficLightRect = union.insetBy(dx: -10, dy: -10)
    }

    @objc func showMainWindow() {
        if window == nil {
            buildMainWindow()
        }
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

    // MARK: - 顶栏拖拽

    private func installMouseMonitor() {
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            guard let self, let window = self.window, let content = window.contentView,
                  window.isVisible else { return event }
            // 顶部 6pt 交给系统做窗口缩放，不能抢
            if event.locationInWindow.y >= content.bounds.height - 6 { return event }
            // 红绿灯区域必须放行，否则按钮点不动
            if self.trafficLightRect.contains(event.locationInWindow) { return event }

            let point = content.convert(event.locationInWindow, from: nil)
            let width = max(content.bounds.width, 1)
            let height = max(content.bounds.height, 1)
            let normalized = NSPoint(x: point.x / width, y: 1 - point.y / height)
            // 落在按钮/输入框上的点击绝不吞掉，否则会出现“点按钮变成拖窗口”
            guard !self.model.avoidZones.contains(where: { $0.contains(normalized) }) else {
                return event
            }
            guard self.model.dragZones.contains(where: { $0.contains(normalized) }) else {
                return event
            }
            if event.clickCount == 2 {
                window.performZoom(nil)
            } else {
                // 拖动时换成不重算背景的材质：否则每帧重算 backdrop 会闪
                self.setBackdropTransient(true)
                window.performDrag(with: event)
                self.setBackdropTransient(false)
            }
            return nil
        }
    }

    private func installKeyMonitor() {
        // 保留 ⌘N 作为新建对话的别名（⌘J 走菜单项）
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self else { return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if flags == .command, event.charactersIgnoringModifiers?.lowercased() == "n" {
                self.newChat()
                return nil
            }
            return event
        }
    }

    // MARK: - 动作

    @objc func newChat() {
        showMainWindow()
        model.newChat()
    }

    @objc func openWebSettings() {
        showMainWindow()
        model.openWebSettings()
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

    @objc func openDocs() {
        if let url = URL(string: "https://api-docs.deepseek.com/") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - 自检（DEEPMACOS_SELFTEST=1 时出现）

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

    @objc func selfTestSettings() {
        model.openWebSettings()
    }

    @objc func selfTestMenu() {
        model.openSessionMenu()
    }

    @objc func selfTestMenuProbe() {
        model.inspectSessionMenu()
    }

    @objc func selfTestResize() {
        window?.setContentSize(NSSize(width: 1000, height: 700))
    }

    @objc func selfTestRaise() {
        window?.level = .floating
        window?.orderFrontRegardless()
    }

    @objc func selfTestLight() {
        NSApp.appearance = NSAppearance(named: .aqua)
    }

    @objc func selfTestDark() {
        NSApp.appearance = NSAppearance(named: .darkAqua)
    }

    @objc func selfTestLower() {
        window?.level = .normal
        window?.orderBack(nil)
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
        appMenu.addItem(menuItem("设置…", #selector(openWebSettings), ","))
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
        fileMenu.addItem(menuItem("新建对话", #selector(newChat), "j"))
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
            testMenu.addItem(menuItem("打开桌面设置", #selector(selfTestSettings), ""))
            testMenu.addItem(menuItem("打开会话菜单", #selector(selfTestMenu), ""))
            testMenu.addItem(menuItem("菜单定位探针", #selector(selfTestMenuProbe), ""))
            testMenu.addItem(menuItem("改窗口大小（测试）", #selector(selfTestResize), ""))
            testMenu.addItem(menuItem("浮到最前（临时）", #selector(selfTestRaise), ""))
            testMenu.addItem(menuItem("窗口置回", #selector(selfTestLower), ""))
            testMenu.addItem(menuItem("浅色外观", #selector(selfTestLight), ""))
            testMenu.addItem(menuItem("深色外观", #selector(selfTestDark), ""))
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
        let settings = NSMenuItem(title: "设置…", action: #selector(openWebSettings), keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)
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
            error.pointee = "该功能未启用：请在 设置 → 桌面应用 → 增强功能 中开启" as NSString
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
