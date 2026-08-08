import AppKit

// точка входа без NIB: делегат ставим руками, иначе AppKit его не подхватит
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
