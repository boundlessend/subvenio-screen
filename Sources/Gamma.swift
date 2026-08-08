import AppKit
import CoreGraphics

enum GammaError: LocalizedError {
    case applyFailed(code: CGError)

    var errorDescription: String? {
        switch self {
        case let .applyFailed(code):
            return String(
                format: String(localized: "could not apply the gamma table, CGError %lld"),
                Int(code.rawValue)
            )
        }
    }
}

/// поканальные таблицы для CGSetDisplayTransferByTable: вход это доля яркости,
/// выход это она же после инверсии, гаммы, клиппинга и тинта
func gammaTables(_ settings: GammaSettings, size: Int) -> (red: [Float], green: [Float], blue: [Float]) {
    func channel(tint: Float) -> [Float] {
        (0..<size).map { index in
            var value = Float(index) / Float(size - 1)
            if settings.invert {
                value = 1 - value
            }
            value = powf(value, 1 / settings.gamma)
            value = settings.blackPoint + (settings.whitePoint - settings.blackPoint) * value
            return min(max(value * tint, 0), 1)
        }
    }
    return (channel(tint: settings.tint[0]), channel(tint: settings.tint[1]), channel(tint: settings.tint[2]))
}

/// бэкенд уровня 1: преобразование уезжает в scanout, поэтому покрывает курсор,
/// меню-бар и Dock и не стоит ничего по нагрузке
final class GammaController {
    private var active: GammaSettings?
    private var activeDisplayID: CGDirectDisplayID = CGMainDisplayID()

    init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(reapply),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        // после сна и смены цветового профиля система сбрасывает таблицу на свою
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(reapply),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        installRestoreOnSignals()
    }

    func activate(_ settings: GammaSettings, displayID: CGDirectDisplayID) throws {
        try apply(settings, displayID: displayID)
        active = settings
        activeDisplayID = displayID
    }

    func deactivate() {
        guard active != nil else { return }
        active = nil
        CGDisplayRestoreColorSyncSettings()
    }

    private func apply(_ settings: GammaSettings, displayID display: CGDirectDisplayID) throws {
        let capacity = Int(CGDisplayGammaTableCapacity(display))
        let tables = gammaTables(settings, size: capacity)
        let result = CGSetDisplayTransferByTable(
            display,
            UInt32(capacity),
            tables.red,
            tables.green,
            tables.blue
        )
        guard result == .success else {
            throw GammaError.applyFailed(code: result)
        }
    }

    @objc private func reapply() {
        guard let active else { return }
        do {
            try apply(active, displayID: activeDisplayID)
        } catch {
            NSLog("не удалось переприменить гамму: \(error.localizedDescription)")
        }
    }
}

// ponytail: CGDisplayRestoreColorSyncSettings формально не async-signal-safe, но оставить
// пользователю перекрашенный экран хуже, чем нарушить букву POSIX в обработчике сигнала.
// SIGKILL не перехватывается вовсе, там гамму восстанавливает сам WindowServer
private func installRestoreOnSignals() {
    for code in [SIGTERM, SIGINT, SIGHUP] {
        signal(code) { _ in
            CGDisplayRestoreColorSyncSettings()
            _exit(1)
        }
    }
}
