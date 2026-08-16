import Foundation

/// следит за папкой плагинов через FSEvents. без этого пришлось бы пересканировать
/// её на каждое открытие меню, то есть читать и парсить десяток файлов синхронно
/// на главном потоке ради клика по иконке
final class PluginWatcher {
    /// изоляция объявлена, а не подразумевается: очередь событий задана главной строкой
    /// ниже, и без пометки колбэк звал бы @MainActor-код из ниоткуда - на Swift 6 это ошибка
    private let onChange: @MainActor @Sendable () -> Void
    private var stream: FSEventStreamRef?

    init(directory: URL, onChange: @escaping @MainActor @Sendable () -> Void) {
        self.onChange = onChange

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            // очередь потока задана главной, поэтому это утверждение, а не надежда
            MainActor.assumeIsolated {
                Unmanaged<PluginWatcher>.fromOpaque(info).takeUnretainedValue().onChange()
            }
        }

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [directory.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            // события копятся 0.3 секунды: сохранение шейдера в редакторе идёт пачкой
            0.3,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents)
        ) else {
            Log.plugins.error("could not watch \(directory.path, privacy: .public)")
            return
        }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}
