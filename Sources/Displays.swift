import AppKit

extension NSScreen {
    /// идентификатор дисплея, которым оперируют CoreGraphics и ScreenCaptureKit
    var displayID: CGDirectDisplayID {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
            ?? CGMainDisplayID()
    }
}

struct DisplayChoice: Identifiable, Hashable {
    let id: CGDirectDisplayID
    let name: String
}

func availableDisplays() -> [DisplayChoice] {
    NSScreen.screens.map { DisplayChoice(id: $0.displayID, name: $0.localizedName) }
}

/// экран по идентификатору, nil если монитор отключили, пока приложение работало.
/// без отката на главный: эффект должен лежать там, где его просили, а исчезновение
/// дисплея это событие, о котором пользователю говорят, а не подменяют молча
func screen(for displayID: CGDirectDisplayID) -> NSScreen? {
    NSScreen.screens.first { $0.displayID == displayID }
}

/// доля кадра дисплея, которую занимает рамка: на весь экран это (0, 0, 1, 1).
/// начало сверху слева, как у текстуры захвата
func sourceRect(for frame: CGRect, on screen: NSScreen) -> CGRect {
    let bounds = screen.frame
    return CGRect(
        x: (frame.minX - bounds.minX) / bounds.width,
        y: (bounds.maxY - frame.maxY) / bounds.height,
        width: frame.width / bounds.width,
        height: frame.height / bounds.height
    )
}
