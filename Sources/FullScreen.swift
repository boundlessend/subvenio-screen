import AppKit
import IOKit.pwr_mgt

/// невидимое окно в точку, которое живёт на всех пространствах, кроме полноэкранных.
/// публичного API, который сказал бы, что чужое приложение ушло в полный экран, нет,
/// а окно с .fullScreenNone в такое пространство не попадает: по нему это и видно
final class FullScreenProbe: NSWindow {
    /// сколько ждать, пока свежий зонд осядет: система уносит его из полноэкранного
    /// пространства через два десятка миллисекунд, остальное запас на занятую машину
    static let settleTime: TimeInterval = 0.5

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenNone, .stationary, .ignoresCycle]
        // выводится сразу, а не к первому вопросу: только что выведенное окно ещё
        // десятки миллисекунд числится на текущем пространстве, даже полноэкранном
        orderFrontRegardless()
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// пространство определяется дисплеем, на котором стоит окно
    func place(on screen: NSScreen) {
        setFrameOrigin(screen.frame.origin)
    }

    /// дисплей зонда сейчас показывает чужое приложение в полном экране
    var isCoveredByFullScreen: Bool { !isOnActiveSpace }
}

/// решает, уступает ли эффект полноэкранному видео на своём дисплее, и зовёт onChange,
/// когда ответ меняется. полноэкранный редактор или терминал эффект не снимает: только
/// приложение, которое держит дисплей бодрствующим, то есть играет видео
@MainActor
final class FullScreenVideoWatch {
    /// начало воспроизведения уже в полном экране пространство не меняет и ничем
    /// не объявляется, поэтому полный экран без видео опрашивается. раз в секунду
    /// это 0.2 мс работы: список окон и запреты сна
    private static let pollInterval: TimeInterval = 1

    var onChange: (() -> Void)?
    private let probe = FullScreenProbe()
    private var displayID = CGMainDisplayID()
    /// эффект включён и ждёт ответов: выключенному следить не за чем
    private var isWatching = false
    /// эффект уже уступил этому полноэкранному пространству. на паузе плеер отпускает
    /// запрет сна, но возвращать эффект поверх остановленного кадра незачем
    private var yields = false
    private var poll: Timer?

    init() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(recheck),
            name: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil
        )
    }

    /// уступает ли эффект видео на этом экране. дальше смену ответа приносит onChange
    func yieldsToVideo(on screen: NSScreen) -> Bool {
        // уступка относилась к пространству прежнего дисплея
        if screen.displayID != displayID {
            yields = false
        }
        displayID = screen.displayID
        probe.place(on: screen)
        isWatching = true
        yields = answer()
        updatePoll()
        // зонд, выведенный или переставленный только что, отвечает предварительно:
        // система уносит его в нужное пространство через десятки миллисекунд и молча
        DispatchQueue.main.asyncAfter(deadline: .now() + FullScreenProbe.settleTime) { [weak self] in
            MainActor.assumeIsolated { self?.recheck() }
        }
        return yields
    }

    func stop() {
        isWatching = false
        yields = false
        updatePoll()
    }

    private func answer() -> Bool {
        guard probe.isCoveredByFullScreen else { return false }
        return yields || displayPlaysVideo(displayID)
    }

    @objc private func recheck() {
        guard isWatching else { return }
        updatePoll()
        guard answer() != yields else { return }
        onChange?()
    }

    private func updatePoll() {
        let needed = isWatching && !yields && probe.isCoveredByFullScreen
        guard needed != (poll != nil) else { return }
        poll?.invalidate()
        poll = nil
        guard needed else { return }
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.recheck() }
        }
        timer.tolerance = Self.pollInterval / 2
        RunLoop.main.add(timer, forMode: .common)
        poll = timer
    }
}

/// на дисплее играет видео: приложение, чьё окно на нём лежит, держит дисплей бодрствующим.
/// так делают плееры и браузеры, пока играют, и отпускают на паузе. утилиты вроде
/// caffeinate держат запрет от своего имени, окон на дисплее у них нет, и сюда они не попадают
func displayPlaysVideo(_ displayID: CGDirectDisplayID) -> Bool {
    let bounds = CGDisplayBounds(displayID)
    let ownPID = getpid()
    let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
        as? [[String: Any]] ?? []
    let owners = Set(windows.compactMap { entry -> pid_t? in
        guard (entry[kCGWindowLayer as String] as? Int) == 0,
              let pid = entry[kCGWindowOwnerPID as String] as? pid_t,
              pid != ownPID,
              let frame = (entry[kCGWindowBounds as String] as? NSDictionary)
                  .flatMap({ CGRect(dictionaryRepresentation: $0 as CFDictionary) }),
              frame.intersects(bounds) else {
            return nil
        }
        return pid
    })
    return !owners.isDisjoint(with: processesKeepingDisplayAwake())
}

/// Chrome до сих пор берёт устаревший тип запрета, константа которого в SDK помечена
/// deprecated, поэтому он назван строкой
private let displayAwakeAssertionTypes: Set<String> = [
    kIOPMAssertionTypePreventUserIdleDisplaySleep,
    "NoDisplaySleepAssertion"
]

private func processesKeepingDisplayAwake() -> Set<pid_t> {
    var assertions: Unmanaged<CFDictionary>?
    let result = IOPMCopyAssertionsByProcess(&assertions)
    guard result == kIOReturnSuccess,
          let byProcess = assertions?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else {
        Log.effects.error("could not read power assertions, IOReturn \(result)")
        return []
    }
    return Set(byProcess.compactMap { pid, list -> pid_t? in
        let keepsAwake = list.contains { assertion in
            displayAwakeAssertionTypes.contains(assertion[kIOPMAssertionTypeKey] as? String ?? "")
        }
        return keepsAwake ? pid.int32Value : nil
    })
}
