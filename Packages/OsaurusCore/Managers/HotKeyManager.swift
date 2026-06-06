//
//  HotKeyManager.swift
//  osaurus
//
//  Created by Terence on 10/26/25.
//

import AppKit
import Carbon.HIToolbox

@MainActor
final class HotKeyManager {
    static let shared = HotKeyManager()

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var action: (() -> Void)?

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
            self.eventHandlerRef = nil
        }
        action = nil
    }

    // MARK: - Generic registration using Chat Hotkey model
    func register(hotkey: Hotkey?, handler: @escaping () -> Void) {
        unregister()
        guard let hotkey else {
            NSLog("[HotKeyManager] register called with nil hotkey — nothing registered")
            return
        }
        NSLog(
            "[HotKeyManager] registering hotkey '\(hotkey.displayString)' keyCode=\(hotkey.keyCode) modifiers=\(hotkey.carbonModifiers)"
        )
        action = handler

        var hotKeyID = EventHotKeyID()
        hotKeyID.signature = OSType(0x4F53_5553)  // 'OSUS'
        hotKeyID.id = UInt32(100)

        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            hotkey.keyCode,
            hotkey.carbonModifiers,
            hotKeyID,
            GetEventDispatcherTarget(),
            UInt32(0),
            &ref
        )
        NSLog("[HotKeyManager] RegisterEventHotKey status=\(status) (0 = noErr)")
        if status == noErr { hotKeyRef = ref }

        var eventSpec = EventTypeSpec(
            eventClass: OSType(UInt32(kEventClassKeyboard)),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let selfPtr = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        let handlerUPP: EventHandlerUPP = { _, event, userData in
            guard let event else { return noErr }
            var hkID = EventHotKeyID()
            let size = MemoryLayout.size(ofValue: hkID)
            let err = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                size,
                nil,
                &hkID
            )
            if err == noErr && hkID.signature == OSType(0x4F53_5553) {
                NSLog("[HotKeyManager] hotkey event FIRED — invoking handler")
                if let userData {
                    let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
                    Task { @MainActor in manager.action?() }
                }
                return noErr
            }
            return OSStatus(eventNotHandledErr)
        }
        var refHandler: EventHandlerRef?
        let installStatus = InstallEventHandler(
            GetEventDispatcherTarget(),
            handlerUPP,
            1,
            &eventSpec,
            selfPtr,
            &refHandler
        )
        NSLog("[HotKeyManager] InstallEventHandler status=\(installStatus) (0 = noErr)")
        if installStatus == noErr { eventHandlerRef = refHandler }
    }
}
