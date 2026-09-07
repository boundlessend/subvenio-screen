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

/// экран, на котором лежит рамка: тот, с которым у неё наибольшее пересечение.
/// нужен оконному режиму, где дисплей задаёт само окно, а не выбор в настройках:
/// иначе доли кадра считались бы от чужого экрана и уходили за пределы [0, 1]
func screen(containing frame: CGRect) -> NSScreen? {
    NSScreen.screens.max { left, right in
        left.frame.intersection(frame).area < right.frame.intersection(frame).area
    }
}

private extension CGRect {
    /// нулевая у пустого пересечения, которое CoreGraphics отдаёт как .null
    var area: CGFloat { isNull || isEmpty ? 0 : width * height }
}

/// доля кадра дисплея, которую занимает рамка: на весь экран это (0, 0, 1, 1).
/// начало сверху слева, как у текстуры захвата, тогда как рамки Cocoa считаются снизу
func sourceRect(for frame: CGRect, in bounds: CGRect) -> CGRect {
    CGRect(
        x: (frame.minX - bounds.minX) / bounds.width,
        y: (bounds.maxY - frame.maxY) / bounds.height,
        width: frame.width / bounds.width,
        height: frame.height / bounds.height
    )
}
