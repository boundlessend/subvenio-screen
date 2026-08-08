import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    /// значение по умолчанию, дальше пользователь переназначает в настройках
    static let toggleEffect = Self(
        "toggleEffect",
        default: .init(.f, modifiers: [.control, .option, .command])
    )
}
