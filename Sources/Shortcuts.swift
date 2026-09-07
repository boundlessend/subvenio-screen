import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    /// значение по умолчанию, дальше пользователь переназначает в настройках
    static let toggleEffect = Self(
        "toggleEffect",
        default: .init(.f, modifiers: [.control, .option, .command])
    )

    /// перебор пресетов без открытия меню: их семнадцать, и выбор следующего
    /// стоил открытия меню или окна настроек каждый раз.
    /// без комбинации по умолчанию: вторая обязательная комбинация отняла бы
    /// у человека ещё одно сочетание, ничего не спросив
    static let nextPreset = Self("nextPreset")
}
