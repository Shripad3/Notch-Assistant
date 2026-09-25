import Carbon.HIToolbox

/// Hold-to-talk on a global hotkey (default ⌥Space). Uses Carbon's
/// RegisterEventHotKey, which reports both press and release and needs no
/// Accessibility permission.
///
/// Escape is registered only while the assistant is busy, so it is never
/// stolen from other apps while idle.
@MainActor
public final class HotkeyActivation: ActivationSource {
    public let events: AsyncStream<ActivationEvent>
    private let continuation: AsyncStream<ActivationEvent>.Continuation

    private let keyCode: UInt32
    private let modifiers: UInt32
    private var handler: EventHandlerRef?
    private var talkKey: EventHotKeyRef?
    private var cancelKey: EventHotKeyRef?
    private var isHeld = false

    private static let signature: OSType = 0x4E_41_53_54 // "NAST"
    private static let talkID: UInt32 = 1
    private static let cancelID: UInt32 = 2

    public init(keyCode: Int = kVK_Space, modifiers: Int = optionKey) {
        self.keyCode = UInt32(keyCode)
        self.modifiers = UInt32(modifiers)
        (events, continuation) = AsyncStream.makeStream()
    }

    public func start() throws {
        guard handler == nil else { return }
        var types = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            hotkeyCallback,
            types.count,
            &types,
            Unmanaged.passUnretained(self).toOpaque(),
            &handler
        )
        guard status == noErr else {
            throw AssistantFailure("Couldn't install the hotkey handler (\(status))")
        }
        let registered = RegisterEventHotKey(
            keyCode, modifiers,
            EventHotKeyID(signature: Self.signature, id: Self.talkID),
            GetApplicationEventTarget(), 0, &talkKey
        )
        guard registered == noErr else {
            throw AssistantFailure("The ⌥Space hotkey is taken by another app")
        }
    }

    public func stop() {
        setCancelKeyEnabled(false)
        if let talkKey { UnregisterEventHotKey(talkKey) }
        if let handler { RemoveEventHandler(handler) }
        talkKey = nil
        handler = nil
    }

    public func setCancelKeyEnabled(_ enabled: Bool) {
        if enabled, cancelKey == nil {
            RegisterEventHotKey(
                UInt32(kVK_Escape), 0,
                EventHotKeyID(signature: Self.signature, id: Self.cancelID),
                GetApplicationEventTarget(), 0, &cancelKey
            )
        } else if !enabled, let key = cancelKey {
            UnregisterEventHotKey(key)
            cancelKey = nil
        }
    }

    fileprivate func handle(id: UInt32, pressed: Bool) {
        switch (id, pressed) {
        case (Self.talkID, true):
            // Carbon repeats the press while the key is held; only the first counts.
            guard !isHeld else { return }
            isHeld = true
            continuation.yield(.triggered)
        case (Self.talkID, false):
            guard isHeld else { return }
            isHeld = false
            continuation.yield(.released)
        case (Self.cancelID, true):
            isHeld = false
            continuation.yield(.cancelled)
        default:
            break
        }
    }
}

/// Carbon delivers hotkey events on the main thread. They are handed to the
/// main actor as a task rather than through MainActor.assumeIsolated, whose
/// runtime executor check crashed this app twice (from here, and from a
/// Combine callback while the notch hid).
private func hotkeyCallback(_: EventHandlerCallRef?, event: EventRef?, userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    var hotkey = EventHotKeyID()
    let status = GetEventParameter(
        event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
        nil, MemoryLayout<EventHotKeyID>.size, nil, &hotkey
    )
    guard status == noErr else { return status }
    let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
    let id = hotkey.id
    let address = UInt(bitPattern: userData)
    Task { @MainActor in
        guard let pointer = UnsafeMutableRawPointer(bitPattern: address) else { return }
        Unmanaged<HotkeyActivation>.fromOpaque(pointer).takeUnretainedValue().handle(id: id, pressed: pressed)
    }
    return noErr
}
