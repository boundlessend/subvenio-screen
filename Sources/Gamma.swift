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
    // таблица из одной записи означала бы деление на ноль ниже; такой дисплей нам не встречался,
    // но емкость приходит из системы, а не из наших рук
    let size = max(size, 2)
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
        // эффект переехал на другой монитор: на прежнем осталась бы наша таблица,
        // и оба дисплея были бы перекрашены до выключения эффекта
        if active != nil, activeDisplayID != displayID {
            CGDisplayRestoreColorSyncSettings()
        }
        try apply(settings, displayID: displayID)
        active = settings
        activeDisplayID = displayID
        gammaIsActive = 1
    }

    func deactivate() {
        guard active != nil else { return }
        active = nil
        gammaIsActive = 0
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
            Log.gamma.error("could not reapply the gamma table: \(error.localizedDescription)")
        }
    }
}

/// читается из обработчика сигнала, поэтому не свойство контроллера, а атомарный флаг
private nonisolated(unsafe) var gammaIsActive: sig_atomic_t = 0

// CGDisplayRestoreColorSyncSettings формально не async-signal-safe, но оставить
// пользователю перекрашенный экран хуже, чем нарушить букву POSIX в обработчике сигнала.
// SIGKILL не перехватывается вовсе, там гамму восстанавливает сам WindowServer
private func installRestoreOnSignals() {
    // аварийные коды здесь наравне со штатными: падение приложения оставляло экран
    // перекрашенным до следующего запуска, а обработчик уже написан и стоит четырёх строк
    for code in [SIGTERM, SIGINT, SIGHUP, SIGSEGV, SIGABRT, SIGILL, SIGBUS, SIGFPE] {
        signal(code) { code in
            // таблицу не трогали: восстанавливать нечего, и чужие настройки цвета целы
            if gammaIsActive != 0 {
                CGDisplayRestoreColorSyncSettings()
            }
            // дальше сигнал доигрывает штатно: код завершения остаётся тем, что послала система
            signal(code, SIG_DFL)
            raise(code)
        }
    }
}
