import Foundation

/// настройки конкретных пресетов: значения ползунков и курсор уровня 3.
/// значения живут в памяти и уезжают на диск пачкой, потому что перетаскивание
/// ползунка иначе пишет UserDefaults шестьдесят раз в секунду
@MainActor
final class PluginSettings {
    private var pending: [String: [Float]] = [:]
    private var flushTimer: Timer?

    /// пользовательские значения, иначе умолчания манифеста
    func parameters(for plugin: ShaderPlugin) -> [Float] {
        if let pending = pending[plugin.identifier] {
            return pending
        }
        let stored = UserDefaults.standard.array(forKey: parametersKey(plugin.identifier)) as? [Double]
        guard let stored, stored.count == plugin.defaultParameters.count else {
            return plugin.defaultParameters
        }
        return stored.map(Float.init)
    }

    /// весь набор значений после правки, или nil если такого ползунка у пресета нет
    func setParameter(_ value: Float, at index: Int, for plugin: ShaderPlugin) -> [Float]? {
        var values = parameters(for: plugin)
        guard values.indices.contains(index) else { return nil }
        values[index] = value
        pending[plugin.identifier] = values
        scheduleFlush()
        return values
    }

    func resetParameters(for plugin: ShaderPlugin) {
        pending[plugin.identifier] = nil
        UserDefaults.standard.removeObject(forKey: parametersKey(plugin.identifier))
    }

    /// курсор внутри кадра на уровне 3 отстаёт на всю задержку пайплайна,
    /// поэтому по умолчанию его рисует система поверх эффекта
    func showsCursor(for plugin: ShaderPlugin) -> Bool {
        UserDefaults.standard.bool(forKey: cursorKey(plugin.identifier))
    }

    func setShowsCursor(_ value: Bool, for plugin: ShaderPlugin) {
        UserDefaults.standard.set(value, forKey: cursorKey(plugin.identifier))
    }

    func flush() {
        flushTimer?.invalidate()
        flushTimer = nil
        for (identifier, values) in pending {
            UserDefaults.standard.set(values.map(Double.init), forKey: parametersKey(identifier))
        }
        pending.removeAll()
    }

    /// пресет удалили с диска: его настройки больше некому читать.
    /// домен берётся свой, а не dictionaryRepresentation: тот отдаёт ещё и системные
    /// ключи вместе с чужими доменами, а искать среди них нечего
    func forget(outside live: Set<String>) {
        let defaults = UserDefaults.standard
        let domain = Bundle.main.bundleIdentifier.flatMap {
            defaults.persistentDomain(forName: $0)
        } ?? [:]
        for key in domain.keys {
            guard let identifier = key.split(separator: ".", maxSplits: 1).last.map(String.init),
                  key.hasPrefix("params.") || key.hasPrefix("cursor."),
                  !live.contains(identifier) else { continue }
            defaults.removeObject(forKey: key)
        }
    }

    private func scheduleFlush() {
        guard flushTimer == nil else { return }
        // таймер главного runloop зовёт замыкание на главном потоке, но типом это не выражено
        let timer = Timer(timeInterval: 0.5, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.flush()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        flushTimer = timer
    }

    private func parametersKey(_ identifier: String) -> String { "params.\(identifier)" }

    private func cursorKey(_ identifier: String) -> String { "cursor.\(identifier)" }
}
