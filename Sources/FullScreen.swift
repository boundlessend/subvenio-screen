import AppKit

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
