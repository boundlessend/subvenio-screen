import AppKit

struct TrackedWindow: Identifiable, Hashable {
    let id: CGWindowID
    let title: String
}

/// список чужих окон на экране. держится на CGWindowList, а не на Accessibility:
/// опрос одного окна по id стоит 0.08 мс, то есть 0.5% ядра на 60 Гц, и это дешевле,
/// чем просить у пользователя ещё одно разрешение
func availableWindows() -> [TrackedWindow] {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
        as? [[String: Any]] ?? []
    let ownPID = Int(getpid())

    return list.compactMap { entry in
        guard let id = entry[kCGWindowNumber as String] as? CGWindowID,
              let pid = entry[kCGWindowOwnerPID as String] as? Int,
              pid != ownPID,
              let owner = entry[kCGWindowOwnerName as String] as? String,
              let bounds = entry[kCGWindowBounds as String] as? [String: CGFloat],
              (bounds["Width"] ?? 0) > 120, (bounds["Height"] ?? 0) > 80 else {
            return nil
        }
        // имя окна без разрешения Screen Recording недоступно, имя приложения доступно всегда
        let name = entry[kCGWindowName as String] as? String
        let title = name.map { "\(owner): \($0)" } ?? owner
        return TrackedWindow(id: id, title: title)
    }
}

/// рамка окна в координатах Cocoa, nil если окно закрыли или свернули
func windowFrame(_ id: CGWindowID) -> CGRect? {
    guard let entry = (CGWindowListCopyWindowInfo([.optionIncludingWindow], id)
        as? [[String: Any]])?.first,
        (entry[kCGWindowIsOnscreen as String] as? Bool) == true,
        let bounds = entry[kCGWindowBounds as String] as? [String: CGFloat],
        let main = NSScreen.screens.first else {
        return nil
    }

    let x = bounds["X"] ?? 0
    let y = bounds["Y"] ?? 0
    let width = bounds["Width"] ?? 0
    let height = bounds["Height"] ?? 0
    // CGWindowList считает Y вниз от верха главного дисплея, Cocoa вверх от его низа
    return CGRect(x: x, y: main.frame.maxY - (y + height), width: width, height: height)
}

/// следит за рамкой окна опросом и дёргает колбэк только когда она изменилась
final class WindowTracker {
    private let windowID: CGWindowID
    private let onChange: (CGRect?) -> Void
    private var timer: Timer?
    private var lastFrame: CGRect?

    // ponytail: оверлей остаётся поверх области, даже если целевое окно перекрыли другим.
    // разбор z-order добавится, если это начнёт мешать
    init(windowID: CGWindowID, onChange: @escaping (CGRect?) -> Void) {
        self.windowID = windowID
        self.onChange = onChange

        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.poll()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        poll()
    }

    deinit {
        timer?.invalidate()
    }

    private func poll() {
        let frame = windowFrame(windowID)
        guard frame != lastFrame else { return }
        lastFrame = frame
        onChange(frame)
    }
}
