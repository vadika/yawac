// yawac/UI/GlobalHotkey.swift
import AppKit
import Carbon.HIToolbox

/// Carbon-based global hotkey registration. The Carbon path is the only
/// one that doesn't trip the macOS Accessibility-permission prompt; the
/// `NSEvent.addGlobalMonitorForEvents` alternative does.
///
/// Hardcoded to ⌘⇧Y for v1 to match the menu-bar Quick-send design.
/// A custom-bind UI is a follow-up; rebind by editing the constants
/// below in the meantime.
@MainActor
final class GlobalHotkey {

    private static let keyCode = UInt32(kVK_ANSI_Y)
    private static let modifiers = UInt32(cmdKey | shiftKey)
    private static let signature: OSType = 0x79617763 // 'yawc'
    private static let hotKeyID: UInt32 = 1

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    /// Boxed closure storage. Carbon's `InstallEventHandler` takes a
    /// raw C callback + `userData` pointer; we route through this box
    /// so the C handler can recover the Swift closure.
    private final class HandlerBox {
        let fire: () -> Void
        init(_ fire: @escaping () -> Void) { self.fire = fire }
    }
    private var box: HandlerBox?

    var isRegistered: Bool { hotKeyRef != nil }

    func register(callback: @escaping () -> Void) {
        guard hotKeyRef == nil else { return }

        let box = HandlerBox(callback)
        self.box = box
        let boxPtr = Unmanaged.passUnretained(box).toOpaque()

        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed))

        let installStatus = InstallEventHandler(
            GetEventDispatcherTarget(),
            { (_: EventHandlerCallRef?, evt: EventRef?, ud: UnsafeMutableRawPointer?) -> OSStatus in
                guard let evt, let ud else { return noErr }
                var hkID = EventHotKeyID()
                let status = GetEventParameter(
                    evt,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hkID)
                guard status == noErr,
                      hkID.signature == GlobalHotkey.signature,
                      hkID.id == GlobalHotkey.hotKeyID else { return noErr }
                let box = Unmanaged<HandlerBox>.fromOpaque(ud).takeUnretainedValue()
                DispatchQueue.main.async { box.fire() }
                return noErr
            },
            1,
            &spec,
            boxPtr,
            &handlerRef)
        guard installStatus == noErr else {
            NSLog("[yawac/hotkey] InstallEventHandler failed status=%d", installStatus)
            self.box = nil
            return
        }

        let id = EventHotKeyID(signature: GlobalHotkey.signature, id: GlobalHotkey.hotKeyID)
        var ref: EventHotKeyRef?
        let registerStatus = RegisterEventHotKey(
            GlobalHotkey.keyCode,
            GlobalHotkey.modifiers,
            id,
            GetEventDispatcherTarget(),
            0,
            &ref)
        if registerStatus == OSStatus(eventHotKeyExistsErr) {
            NSLog("[yawac/hotkey] ⌘⇧Y already registered by another app; skipping")
            if let handlerRef { RemoveEventHandler(handlerRef) }
            handlerRef = nil
            self.box = nil
            return
        }
        guard registerStatus == noErr, let ref else {
            NSLog("[yawac/hotkey] RegisterEventHotKey failed status=%d", registerStatus)
            if let handlerRef { RemoveEventHandler(handlerRef) }
            handlerRef = nil
            self.box = nil
            return
        }
        hotKeyRef = ref
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        hotKeyRef = nil
        if let handlerRef {
            RemoveEventHandler(handlerRef)
        }
        handlerRef = nil
        box = nil
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}
