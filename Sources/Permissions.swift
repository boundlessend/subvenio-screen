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

/// свой экран объяснения до системного диалога, как договорились в PLAN.md.
/// имя пресета в заголовке: разрешение спрашивают восемь разных эффектов,
/// и человек должен видеть, который из них его сейчас попросил
func ensureScreenRecordingAccess(for presetName: String) -> Bool {
    if hasScreenRecordingAccess() {
        return true
    }

    activateApp()
    let explanation = NSAlert()
    explanation.messageText = String(
        format: String(localized: "\"%@\" needs Screen Recording permission"),
        presetName
    )
    explanation.informativeText = String(localized: """
    A gamma table can scale channels separately but cannot mix them, so an effect \
    that reacts to the picture rather than tinting it has to read the screen.

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

    // CGRequestScreenCaptureAccess отвечает состоянием на сейчас, а не ответом
    // человека: системное окно в этот момент ещё открыто. поэтому здесь не отказ,
    // а «пока не выдано», и текст говорит, что делать в обоих случаях.
    // системный диалог показывается один раз за установку, дальше только руками
    activateApp()
    let denied = NSAlert()
    denied.messageText = String(localized: "Permission not granted yet")
    denied.informativeText = String(localized: """
    If you just granted it in the system dialog, turn the effect on again.

    If the dialog did not appear, open Privacy & Security → Screen Recording and \
    enable Subvenio Screen there.
    """)
    denied.addButton(withTitle: String(localized: "Open Settings"))
    denied.addButton(withTitle: String(localized: "Cancel"))
    if denied.runModal() == .alertFirstButtonReturn {
        openScreenRecordingSettings()
    }
    return false
}
