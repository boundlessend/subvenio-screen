import AppKit

/// пользователь сам попросил показать подробности, поэтому здесь модальное окно уместно
func showAlert(title: String, message: String) {
    // без активации окно алерта у LSUIElement-приложения уедет за чужие окна
    activateApp()
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = message
    alert.alertStyle = .warning
    alert.runModal()
}

func activateApp() {
    NSApp.activate()
}

/// свой экран объяснения до системного диалога, как договорились в PLAN.md
func ensureScreenRecordingAccess() -> Bool {
    if hasScreenRecordingAccess() {
        return true
    }

    activateApp()
    let explanation = NSAlert()
    explanation.messageText = String(localized: "This effect needs Screen Recording permission")
    explanation.informativeText = String(localized: """
    A gamma table can scale channels separately but cannot mix them, so an honest \
    black and white effect has to read the picture on screen.

    Frames only live in memory until they are drawn: nothing is written to disk \
    and nothing leaves your machine.

    The system permission dialog opens next.
    """)
    explanation.addButton(withTitle: String(localized: "Continue"))
    explanation.addButton(withTitle: String(localized: "Cancel"))
    guard explanation.runModal() == .alertFirstButtonReturn else { return false }

    if requestScreenRecordingAccess() {
        return true
    }

    // системный диалог показывается один раз за установку, дальше только руками
    activateApp()
    let denied = NSAlert()
    denied.messageText = String(localized: "Permission not granted")
    denied.informativeText = String(localized: "Open Privacy & Security → Screen Recording and enable Subvenio Screen.")
    denied.addButton(withTitle: String(localized: "Open Settings"))
    denied.addButton(withTitle: String(localized: "Cancel"))
    if denied.runModal() == .alertFirstButtonReturn {
        openScreenRecordingSettings()
    }
    return false
}
