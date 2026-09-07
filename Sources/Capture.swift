import AppKit
import CoreVideo
import Metal
import os
import ScreenCaptureKit

enum CaptureError: LocalizedError {
    case accessDenied
    case noDisplay
    case displayGone(id: CGDirectDisplayID)
    case notRunning
    case textureCacheFailed(code: CVReturn)

    var errorDescription: String? {
        switch self {
        case .accessDenied:
            return String(localized: "no Screen Recording permission")
        case .notRunning:
            return String(localized: "the capture stream is not running")
        case .noDisplay:
            return String(localized: "ScreenCaptureKit returned no displays")
        case let .displayGone(id):
            return String(
                format: String(localized: "display %lld is no longer connected"),
                Int(id)
            )
        case let .textureCacheFailed(code):
            return String(
                format: String(localized: "could not create CVMetalTextureCache, code %lld"),
                Int(code)
            )
        }
    }
}

/// рычаги нагрузки уровня 3, общие для всех пресетов: захват в полном разрешении
/// на 120 Гц стоит дорого, а разница на ретро-эффекте почти не видна
struct CaptureQuality: Equatable {
    /// доля нативного разрешения дисплея
    var scale: Double
    /// потолок кадров в секунду, 0 означает частоту дисплея
    var frameRateCap: Int
}

/// разрешение спрашиваем лениво, только когда включают шейдер уровня 3
func hasScreenRecordingAccess() -> Bool {
    CGPreflightScreenCaptureAccess()
}

/// системный диалог, показывается один раз за всё время жизни установки.
/// дальше пользователя надо вести в системные настройки руками
func requestScreenRecordingAccess() -> Bool {
    CGRequestScreenCaptureAccess()
}

func openScreenRecordingSettings() {
    let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
    NSWorkspace.shared.open(url)
}

/// кадр захвата вместе с тем, что удерживает его пиксели живыми.
/// MTLTexture смотрит на IOSurface из пула захвата: отпустишь CVMetalTexture
/// или CVPixelBuffer раньше отрисовки, и пул отдаст поверхность следующему кадру,
/// а на экран попадёт мусор.
///
/// Sendable без проверки компилятора: кадр пересекает поток ровно один раз, от очереди
/// захвата к главному, и после создания не меняется. никто, кроме отрисовки, его не читает
struct CapturedFrame: @unchecked Sendable {
    let texture: MTLTexture
    private let cvTexture: CVMetalTexture
    private let pixelBuffer: CVPixelBuffer

    init(texture: MTLTexture, cvTexture: CVMetalTexture, pixelBuffer: CVPixelBuffer) {
        self.texture = texture
        self.cvTexture = cvTexture
        self.pixelBuffer = pixelBuffer
    }
}

/// то, чем был запущен захват: хранится, чтобы пережить смену разрешения и сон экрана
struct CaptureRequest {
    let plugin: ShaderPlugin
    let parameters: [Float]
    let displayID: CGDirectDisplayID
    /// рамка меняется на ходу вместе с окном под эффектом, остальное задаётся при старте
    var frame: CGRect
    let showsCursor: Bool
    let quality: CaptureQuality
    let onStop: @MainActor @Sendable (Error) -> Void
}

/// то в дисплее, что задаётся при старте потока и не меняется на лету
struct DisplayProfile: Equatable {
    let size: CGSize
    let scale: CGFloat
    let framesPerSecond: Int
}

/// доставляет кадры с очереди захвата на главный поток.
/// отдельный тип, потому что колбэк ScreenCaptureKit приходит вне главного потока,
/// а вью изолировано главным актором
final class FrameSink: @unchecked Sendable {
    private weak var view: OverlayView?
    /// предыдущий кадр ещё не дорисован: следующий выбрасываем, а не ставим в очередь.
    /// очередь главного потока не имеет предела и растёт вместе с задержкой, а каждый
    /// кадр в ней держит поверхность из пула захвата, после чего ScreenCaptureKit
    /// начинает ронять кадры сам
    private let isBusy = OSAllocatedUnfairLock(initialState: false)

    init(view: OverlayView) {
        self.view = view
    }

    func deliver(_ frame: CapturedFrame) {
        let accepted = isBusy.withLock { busy in
            guard !busy else { return false }
            busy = true
            return true
        }
        guard accepted else { return }

        // assumeIsolated вместо Task: очередь главного потока сохраняет порядок кадров
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard let view = self.view else {
                    self.isBusy.withLock { $0 = false }
                    return
                }
                view.render(source: frame.texture) {
                    // кадр держится замыканием до сюда: пул захвата не должен
                    // получить поверхность назад, пока GPU её читает
                    _ = frame
                    self.isBusy.withLock { $0 = false }
                }
            }
        }
    }
}

/// бэкенд уровня 3: захват экрана в текстуру Metal без копирования на CPU.
///
/// потоковый контракт, он же причина `@unchecked Sendable`: изменяемое состояние
/// (`stream`) читается и пишется только на главном акторе, чем и объясняются
/// пометки на start и stop, а с очереди кадров используется единственное
/// неизменяемое поле `textureCache`. поэтому гонки между stop и колбэком нет,
/// но доказать это компилятору нечем
final class CaptureController: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let textureCache: CVMetalTextureCache
    /// зовётся с очереди захвата
    private let onFrame: @Sendable (CapturedFrame) -> Void
    /// зовётся на главном акторе
    private let onStop: @MainActor @Sendable (Error) -> Void

    private var stream: SCStream?
    private let sampleQueue = DispatchQueue(label: "dev.boundlessend.SubvenioScreen.capture")

    init(
        device: MTLDevice,
        onFrame: @escaping @Sendable (CapturedFrame) -> Void,
        onStop: @escaping @MainActor @Sendable (Error) -> Void
    ) throws {
        var cache: CVMetalTextureCache?
        let status = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        guard status == kCVReturnSuccess, let cache else {
            throw CaptureError.textureCacheFailed(code: status)
        }
        self.textureCache = cache
        self.onFrame = onFrame
        self.onStop = onStop
    }

    /// частоту передаёт вызывающий: NSScreen читается только с главного потока,
    /// а поднимать поток захвата отсюда всё равно нельзя.
    /// изоляция здесь не украшение: без неё присваивание stream уезжало бы на пул
    /// конкурентности, пока stop читает его с главного
    @MainActor
    func start(
        displayID: CGDirectDisplayID,
        overlayWindowID: CGWindowID,
        framesPerSecond: Int,
        showsCursor: Bool,
        quality: CaptureQuality
    ) async throws {
        let (filter, configuration) = try await makeStream(
            displayID: displayID,
            overlayWindowID: overlayWindowID,
            framesPerSecond: framesPerSecond,
            showsCursor: showsCursor,
            quality: quality
        )

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        try await stream.startCapture()
        self.stream = stream

        Log.capture.info(
            "captured stream started: \(configuration.width)x\(configuration.height) at \(framesPerSecond) fps"
        )
    }

    /// разрешение дисплея, частота или качество сменились на ходу. поток при этом
    /// не роняется: перезапуск стоит нового согласования с WindowServer и даёт
    /// видимый провал в несколько кадров
    @MainActor
    func update(
        displayID: CGDirectDisplayID,
        overlayWindowID: CGWindowID,
        framesPerSecond: Int,
        showsCursor: Bool,
        quality: CaptureQuality
    ) async throws {
        guard let stream else { throw CaptureError.notRunning }
        let (filter, configuration) = try await makeStream(
            displayID: displayID,
            overlayWindowID: overlayWindowID,
            framesPerSecond: framesPerSecond,
            showsCursor: showsCursor,
            quality: quality
        )
        try await stream.updateContentFilter(filter)
        try await stream.updateConfiguration(configuration)

        Log.capture.info(
            "capture stream updated: \(configuration.width)x\(configuration.height) at \(framesPerSecond) fps"
        )
    }

    @MainActor
    private func makeStream(
        displayID: CGDirectDisplayID,
        overlayWindowID: CGWindowID,
        framesPerSecond: Int,
        showsCursor: Bool,
        quality: CaptureQuality
    ) async throws -> (SCContentFilter, SCStreamConfiguration) {
        guard hasScreenRecordingAccess() else {
            throw CaptureError.accessDenied
        }

        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        guard !content.displays.isEmpty else {
            throw CaptureError.noDisplay
        }
        // без отката на первый попавшийся дисплей: эффект должен лежать там, где просили
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw CaptureError.displayGone(id: displayID)
        }

        // из кадра выпадает ровно оверлей, а не все окна приложения: по pid отсюда
        // выпадало и окно настроек, и человек видел на его месте отфильтрованный
        // рабочий стол. sharingType = .none страховкой больше не служит,
        // с macOS 15.4 ScreenCaptureKit его не смотрит
        let overlay = content.windows.filter { $0.windowID == overlayWindowID }
        let filter = SCContentFilter(display: display, excludingWindows: overlay)

        var framesPerSecond = quality.frameRateCap > 0
            ? min(quality.frameRateCap, framesPerSecond)
            : framesPerSecond
        // режим энергосбережения означает, что человек считает проценты батареи,
        // а не кадры ретро-эффекта
        if ProcessInfo.processInfo.isLowPowerModeEnabled {
            framesPerSecond = min(framesPerSecond, 30)
        }

        let configuration = SCStreamConfiguration()
        // размер берётся у самого фильтра, а не считается из NSScreen: contentRect
        // и pointPixelScale описывают то, что этот фильтр реально отдаст,
        // и на нестандартных масштабах не расходятся с ним
        configuration.width = Int(filter.contentRect.width * CGFloat(filter.pointPixelScale) * quality.scale)
        configuration.height = Int(filter.contentRect.height * CGFloat(filter.pointPixelScale) * quality.scale)
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        // кадр приходит в том же пространстве, в котором оверлей его потом покажет:
        // иначе на Display P3 шейдер получал одни числа, а рисовал по другим,
        // и «честное чёрно-белое» зависело от того, к какому монитору подключились
        configuration.colorSpaceName = CGColorSpace.sRGB
        // по умолчанию курсор рисует система поверх эффекта: попав внутрь кадра, он отстаёт
        // на всю задержку пайплайна и читается как лаг мыши
        configuration.showsCursor = showsCursor
        // пять, а не минимальные три: кадр уезжает на главный поток, и любая заминка
        // там при трёх поверхностях сразу превращается в дропы
        configuration.queueDepth = 5
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(framesPerSecond))

        return (filter, configuration)
    }

    @MainActor
    func stop() {
        guard let stream else { return }
        self.stream = nil
        Log.capture.info("capture stream stopping")
        stream.stopCapture { error in
            if let error {
                Log.capture.error("stream stopped with error: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - SCStreamOutput

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .screen,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              isCompleteFrame(sampleBuffer) else { return }

        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil,
            .bgra8Unorm,
            CVPixelBufferGetWidth(pixelBuffer),
            CVPixelBufferGetHeight(pixelBuffer),
            0,
            &cvTexture
        )
        guard status == kCVReturnSuccess,
              let cvTexture,
              let texture = CVMetalTextureGetTexture(cvTexture) else {
            Log.capture.error("frame did not become an MTLTexture, code \(status)")
            return
        }

        onFrame(CapturedFrame(texture: texture, cvTexture: cvTexture, pixelBuffer: pixelBuffer))
    }

    /// кадры со статусом idle или blank приходят без свежей картинки, рисовать их нельзя
    private func isCompleteFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: false
        ) as? [[SCStreamFrameInfo: Any]],
            let raw = attachments.first?[.status] as? Int else {
            return true
        }
        return SCFrameStatus(rawValue: raw) == .complete
    }

    // MARK: - SCStreamDelegate

    /// сюда прилетает отзыв разрешения в системных настройках. делегат зовут не с главного
    /// потока, а состояние живёт на нём
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.stream = nil
                self?.onStop(error)
            }
        }
    }
}
