import Carbon.HIToolbox

// ponytail: один хоткей на приложение, обработчик хранится глобально, потому что
// Carbon-колбэк это C-функция и контекст не захватывает. под несколько хоткеев
// (волна 5) здесь появится словарь по EventHotKeyID
private var registeredAction: (() -> Void)?

/// глобальный хоткей через Carbon: в отличие от NSEvent.addGlobalMonitorForEvents
/// не требует разрешения Accessibility
final class GlobalHotKey {
    private var reference: EventHotKeyRef?

    init(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        registeredAction = action

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, _ in
                registeredAction?()
                return noErr
            },
            1,
            &eventType,
            nil,
            nil
        )

        let identifier = EventHotKeyID(signature: OSType(0x5343_4652), id: 1)
        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            identifier,
            GetApplicationEventTarget(),
            0,
            &reference
        )
        if status != noErr {
            NSLog("не удалось зарегистрировать хоткей, код ошибки: \(status)")
        }
    }

    deinit {
        if let reference {
            UnregisterEventHotKey(reference)
        }
    }
}
