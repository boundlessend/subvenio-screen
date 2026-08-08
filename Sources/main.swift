import AppKit

// точка входа без NIB: делегат ставим руками, иначе AppKit его не подхватит.
// код верхнего уровня исполняется вне актора, а AppKit изолирован главным.
// delegate у NSApplication слабый, поэтому ссылка держится кадром run()
MainActor.assumeIsolated {
    let delegate = AppDelegate()
    let app = NSApplication.shared
    app.delegate = delegate
    app.run()
}
