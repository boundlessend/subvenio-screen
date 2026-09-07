import AppKit

/// имя распределённого уведомления, которым вторая копия просит первую показаться.
/// без него повторный запуск из Finder не делал ничего видимого, а это единственный
/// путь к приложению, когда иконка в меню-баре уехала в переполнение и хоткей забыт
let showSettingsNotification = Notification.Name(
    "dev.boundlessend.SubvenioScreen.showSettings"
)

/// вторая копия это вторая иконка в меню-баре и вторая гамма-таблица на том же
/// дисплее: выключение одной оставило бы экран перекрашенным второй.
/// проверка живёт до создания делегата, потому что его свойства успевают записать
/// в папку пресетов и завести наблюдателя за ней
func anotherCopyIsRunning() -> Bool {
    guard let identifier = Bundle.main.bundleIdentifier else { return false }
    return NSRunningApplication
        .runningApplications(withBundleIdentifier: identifier)
        .contains { $0 != .current }
}

func askRunningCopyToShowSettings() {
    Log.effects.info("another copy is already running, asking it to show settings")
    // sandbox пропускает распределённое уведомление только с пустым object
    DistributedNotificationCenter.default().postNotificationName(
        showSettingsNotification,
        object: nil,
        userInfo: nil,
        deliverImmediately: true
    )
}
