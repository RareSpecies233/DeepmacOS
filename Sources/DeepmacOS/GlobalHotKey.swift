import AppKit
import Carbon.HIToolbox
import Foundation

/// 全局快捷键（Carbon RegisterEventHotKey，不需要辅助功能权限）。
/// 默认不注册：只有在设置里显式开启后才会占用按键。
@MainActor
final class GlobalHotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var onTrigger: (() -> Void)?
    private static var active: GlobalHotKey?

    var isRegistered: Bool { hotKeyRef != nil }

    /// 注册 ⌥Space；成功返回 true
    @discardableResult
    func register(trigger: @escaping () -> Void) -> Bool {
        unregister()
        onTrigger = trigger

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let callback: EventHandlerUPP = { _, _, _ in
            DispatchQueue.main.async {
                Task { @MainActor in
                    GlobalHotKey.active?.fire()
                }
            }
            return noErr
        }
        let install = InstallEventHandler(GetApplicationEventTarget(), callback, 1, &eventType, nil, &handlerRef)
        guard install == noErr else {
            handlerRef = nil
            return false
        }

        let hotKeyID = EventHotKeyID(signature: OSType(0x444D_4153), id: 1)
        let status = RegisterEventHotKey(
            UInt32(kVK_Space),
            UInt32(optionKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        guard status == noErr else {
            unregister()
            return false
        }
        GlobalHotKey.active = self
        return true
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let handlerRef {
            RemoveEventHandler(handlerRef)
            self.handlerRef = nil
        }
        if GlobalHotKey.active === self {
            GlobalHotKey.active = nil
        }
        onTrigger = nil
    }

    private func fire() {
        onTrigger?()
    }
}
