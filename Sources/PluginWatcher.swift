import Foundation

/// следит за папкой плагинов через FSEvents. без этого пришлось бы пересканировать
/// её на каждое открытие меню, то есть читать и парсить десяток файлов синхронно
/// на главном потоке ради клика по иконке
final class PluginWatcher {
    private let onChange: () -> Void
    private var stream: FSEventStreamRef?

    init(directory: URL, onChange: @escaping () -> Void) {
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
            Unmanaged<PluginWatcher>.fromOpaque(info).takeUnretainedValue().onChange()
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
