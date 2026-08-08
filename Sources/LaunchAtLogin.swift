import ServiceManagement

/// автозапуск через SMAppService: helper-бандл и возня с подписью не нужны,
/// но система запомнит именно тот путь, из которого приложение зарегистрировали
func isLaunchAtLoginEnabled() -> Bool {
    SMAppService.mainApp.status == .enabled
}

func setLaunchAtLogin(_ enabled: Bool) throws {
    if enabled {
        try SMAppService.mainApp.register()
    } else {
        try SMAppService.mainApp.unregister()
    }
}
