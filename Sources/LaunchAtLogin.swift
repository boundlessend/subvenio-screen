import ServiceManagement

/// три состояния вместо двух: система умеет держать регистрацию, которую человек
/// выключил в Login Items, и переключатель, знающий только «включено» и «выключено»,
/// в этом случае молча отскакивал назад
enum LaunchAtLoginState {
    case enabled
    case requiresApproval
    case disabled
}

/// автозапуск через SMAppService: helper-бандл и возня с подписью не нужны,
/// но система запомнит именно тот путь, из которого приложение зарегистрировали
func launchAtLoginState() -> LaunchAtLoginState {
    switch SMAppService.mainApp.status {
    case .enabled: return .enabled
    case .requiresApproval: return .requiresApproval
    default: return .disabled
    }
}

func setLaunchAtLogin(_ enabled: Bool) throws {
    if enabled {
        try SMAppService.mainApp.register()
    } else {
        try SMAppService.mainApp.unregister()
    }
}

/// пункт включают там, а не у нас: свой переключатель регистрацию вернуть может,
/// а снятую человеком галочку в системных настройках нет
func openLoginItemsSettings() {
    SMAppService.openSystemSettingsLoginItems()
}
