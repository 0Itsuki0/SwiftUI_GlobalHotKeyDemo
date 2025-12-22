
@preconcurrency import ApplicationServices
import Cocoa
@preconcurrency import Combine
import SwiftUI

struct GlobalHotkeyAdvance: View {
    @State private var hotkeyManager: HotkeyManager?
    @State private var targetHotkeyDown: Bool = false

    var body: some View {
        VStack {
            Text("Watching for Command + S")
            Text("Is HotKey Detected: \(String(targetHotkeyDown)) ")
        }
        .onAppear {
            self.hotkeyManager = HotkeyManager(onError: { error in
                print(error)
            }, targetModifierFlags: [.command], targetKeyCode: 1, onTargetHotkeyDown: { bool in
                self.targetHotkeyDown = bool
            })
        }
    }
    
}


private enum AccessibilityError: Error, LocalizedError {
    case accessibilityPermissionNotGranted
    var errorDescription: String? {
        switch self  {
        case .accessibilityPermissionNotGranted:
            "accessibilityPermissionNotGranted"
        }
    }
}


extension Notification.Name {
    nonisolated var publisher: NotificationCenter.Publisher {
        return NotificationCenter.default.publisher(for: self)
    }
}

nonisolated final class AccessibilityManager {
    var onPermissionChange: (() -> Void)?

    static func checkAccessibilityPermission() throws {
        try self.requestPermissionHelper(displayPrompt: false)
    }

    static func requestAccessibilityPermission() {
        // not throwing here because this is intended to be called to prompt for permission instead of showing error
        try? self.requestPermissionHelper(displayPrompt: true)
    }

    private static func requestPermissionHelper(displayPrompt: Bool) throws {
        let options: NSDictionary = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: displayPrompt
        ]

        let accessEnabled = AXIsProcessTrustedWithOptions(options)

        if !accessEnabled {
            throw AccessibilityError.accessibilityPermissionNotGranted
        }
    }

    private var cancellable: AnyCancellable?

    init() {
        self.cancellable = NSWorkspace
            .accessibilityDisplayOptionsDidChangeNotification.publisher.receive(
                on: DispatchQueue.main
            ).sink { _ in
                self.onPermissionChange?()
            }
    }

    deinit {
        self.cancellable?.cancel()
        self.cancellable = nil
    }
}

enum HotkeyError: Error, LocalizedError {
    case failedToCreateEventTap

    var errorDescription: String? {
        switch self {
        case .failedToCreateEventTap:
            "failedToCreateKeyboard Event Listener"
        }
    }
}


nonisolated final class HotkeyManager: @unchecked Sendable {
    static let defaultHotkeyModifiers: NSEvent.ModifierFlags = [
        .command, .shift,
    ]
    static let spaceKey: UInt16 = 49
    static let defaultHotkeyKey: UInt16 = spaceKey

    private let onError: (Error) -> Void

    private let onTargetHotkeyDown: (Bool) -> Void

    private let targetModifierFlags: NSEvent.ModifierFlags
    private let targetKeyCode: UInt16

    private var holdingKeys: Set<UInt16> = []
    private var holdingModifiers: NSEvent.ModifierFlags = []

    private var eventTap: CFMachPort?

    private var accessibilityManager = AccessibilityManager()

    init(
        onError: @escaping (Error) -> Void,
        targetModifierFlags: NSEvent.ModifierFlags,
        targetKeyCode: UInt16,
        onTargetHotkeyDown: @escaping (Bool) -> Void
    ) {
        self.onError = onError
        self.onTargetHotkeyDown = onTargetHotkeyDown
        self.targetKeyCode = targetKeyCode
        self.targetModifierFlags = targetModifierFlags
        self.accessibilityManager.onPermissionChange = self.handleAccessibilityPermissionsChange

        do {
            try AccessibilityManager.checkAccessibilityPermission()
            self.setupKeyPressMonitor()
        } catch (let error) {
            self.onError(error)
        }
    }

    deinit {
        self.removeKeyPressMonitor()
    }

    private func handleError(_ error: Error) {
        self.removeKeyPressMonitor()
        self.onError(error)
    }

    func setupKeyPressMonitor() {
        guard self.eventTap == nil else { return }
        
        // CGEventType: https://developer.apple.com/documentation/coregraphics/cgeventtype
        let eventMask = CGEventMask(
            (1 << CGEventType.keyDown.rawValue)
                | (1 << CGEventType.keyUp.rawValue)
                | (1 << CGEventType.flagsChanged.rawValue)
        )

        let callback: CGEventTapCallBack = { (proxy, type, event, me) in
            guard let manager = me else {
                return nil
            }
            let wrapper = Unmanaged<HotkeyManager>.fromOpaque(manager)
                .takeUnretainedValue()
            return wrapper.handleEvent(
                proxy: proxy,
                type: type,
                event: event,
                userInfo: manager
            )
        }

        guard
            let eventTap: CFMachPort = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: eventMask,
                callback: callback,
                userInfo: Unmanaged.passUnretained(self).toOpaque()
            )
        else {
            self.handleError(HotkeyError.failedToCreateEventTap)
            return
        }

        self.eventTap = eventTap

        // Creates a CFRunLoopSource object for a CFMachPort object.
        // https://developer.apple.com/documentation/CoreFoundation/CFMachPortCreateRunLoopSource(_:_:_:)
        let runLoopSource = CFMachPortCreateRunLoopSource(
            kCFAllocatorDefault,
            eventTap,
            0
        )

        // add the source to a run loop
        // https://developer.apple.com/documentation/corefoundation/cfrunloopaddsource(_:_:_:)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)

        // Event taps are normally enabled when created. If an event tap becomes unresponsive, or if a user requests that event taps be disabled, then a kCGEventTapDisabled event is passed to the event tap callback function. Event taps may be re-enabled by calling this function.
        CGEvent.tapEnable(tap: eventTap, enable: true)
    }

    func removeKeyPressMonitor() {
        guard let eventTap = self.eventTap else { return }
        
        CGEvent.tapEnable(tap: eventTap, enable: false)
        self.eventTap = nil
    }

    // The callback function that handles key down events
    private func handleEvent(
        proxy: CGEventTapProxy,
        type: CGEventType,
        event: CGEvent,
        userInfo: UnsafeMutableRawPointer?
    ) -> Unmanaged<CGEvent>? {
        // Return the event to allow it to continue to the active app
        guard let nsEvent = NSEvent(cgEvent: event) else {
            return Unmanaged.passUnretained(event)
        }

        // make sure to not swallow event when it is not part of the target
        switch type {
        case CGEventType.keyDown:
            self.processKeydown(nsEvent)
        case CGEventType.keyUp:
            self.processKeyup(nsEvent)
        case CGEventType.flagsChanged:
            self.processModifierFlagChange(nsEvent)
        default:
            return Unmanaged.passUnretained(event)
        }

        // only swallowing when the **entire combination** is the target
        // otherwise, release the event
        let targetKeyDown = self.checkTargetHotkeyDown()
        self.onTargetHotkeyDown(targetKeyDown)

        return targetKeyDown ? nil : Unmanaged.passUnretained(event)
    }

    private func processKeyup(_ event: NSEvent) {
        self.holdingKeys.remove(event.keyCode)
    }

    private func processKeydown(_ event: NSEvent) {
        if !self.holdingKeys.contains(event.keyCode) {
            self.holdingKeys.insert(event.keyCode)
        }
    }

    private func processModifierFlagChange(_ event: NSEvent) {
        // masking with deviceIndependentFlagsMask for consistently across all hardware.
        // Not really necessary in this case...
        let newFlags = event.modifierFlags.intersection(
            .deviceIndependentFlagsMask
        )
        if self.holdingModifiers != newFlags {
            self.holdingModifiers = newFlags
        }
    }

    private func checkTargetHotkeyDown() -> Bool {
        return self.holdingKeys == Set([self.targetKeyCode])
            && self.holdingModifiers == self.targetModifierFlags
    }

    private func handleAccessibilityPermissionsChange() {
        // The notification is generic, so you should re-check the actual status
        // to ensure the change applies to your app. A small delay might be needed
        // for the changes to be fully reflected in the system's database.
        DispatchQueue.global(qos: .background).asyncAfter(
            deadline: .now() + 0.5
        ) { [weak self] in
            guard let self else { return }

            do {
                try AccessibilityManager.checkAccessibilityPermission()
                self.setupKeyPressMonitor()
            } catch (let error) {
                self.handleError(error)
            }
        }
    }
}
