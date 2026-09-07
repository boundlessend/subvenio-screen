import AppKit

// точка входа без NIB: делегат ставим руками, иначе AppKit его не подхватит.
// код верхнего уровня исполняется вне актора, а AppKit изолирован главным.
// delegate у NSApplication слабый, поэтому ссылка держится кадром run()
MainActor.assumeIsolated {
    // проверка до создания делегата: его свойства поднимают контроллер эффекта,
    // а тот пишет в папку пресетов и заводит наблюдателя за ней. вторая копия
    // делала всё это и только потом узнавала, что она вторая
    guard !anotherCopyIsRunning() else {
        askRunningCopyToShowSettings()
        exit(0)
    }
    let delegate = AppDelegate()
    let app = NSApplication.shared
    app.delegate = delegate
    app.run()
}
