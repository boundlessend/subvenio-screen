import AppKit
import CoreVideo
import Metal
import ScreenCaptureKit

enum CaptureError: LocalizedError {
    case accessDenied
    case noDisplay
    case displayGone(id: CGDirectDisplayID)
    case textureCacheFailed(code: CVReturn)

    var errorDescription: String? {
        switch self {
        case .accessDenied:
            return String(localized: "no Screen Recording permission")
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
    let scale: Double
    /// потолок кадров в секунду, 0 означает частоту дисплея
    let frameRateCap: Int

    static let native = CaptureQuality(scale: 1, frameRateCap: 0)
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

/// бэкенд уровня 3: захват экрана в текстуру Metal без копирования на CPU.
///
/// потоковый контракт, он же причина `@unchecked Sendable`: изменяемое состояние
/// (`stream`) читается и пишется только на главном потоке, а с очереди кадров
/// используется единственное неизменяемое поле `textureCache`. поэтому гонки
/// между stop и колбэком нет, но доказать это компилятору нечем
final class CaptureController: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let textureCache: CVMetalTextureCache
    /// зовётся с очереди захвата
    private let onFrame: @Sendable (CapturedFrame) -> Void
    /// зовётся на главном акторе
    private let onStop: @MainActor @Sendable (Error) -> Void

    private var stream: SCStream?
    private let sampleQueue = DispatchQueue(label: "dev.senya.SubvenireScreen.capture")

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

    /// масштаб и частоту передаёт вызывающий: NSScreen читается только с главного потока,
    /// а старт потока живёт вне его
    func start(
        displayID: CGDirectDisplayID,
        scale: CGFloat,
        framesPerSecond: Int,
        showsCursor: Bool,
        quality: CaptureQuality
    ) async throws {
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

        // собственные окна вон из захвата, иначе кадр попадёт сам в себя и пойдёт петля.
        // вместе с sharingType = .none у оверлейного окна это закрывает вопрос с двух сторон
        let ownWindows = content.windows.filter { $0.owningApplication?.processID == getpid() }
        let filter = SCContentFilter(display: display, excludingWindows: ownWindows)

        let pixelScale = scale * quality.scale
        var framesPerSecond = quality.frameRateCap > 0
            ? min(quality.frameRateCap, framesPerSecond)
            : framesPerSecond
        // режим энергосбережения означает, что человек считает проценты батареи,
        // а не кадры ретро-эффекта
        if ProcessInfo.processInfo.isLowPowerModeEnabled {
            framesPerSecond = min(framesPerSecond, 30)
        }

        let configuration = SCStreamConfiguration()
        configuration.width = Int(CGFloat(display.width) * pixelScale)
        configuration.height = Int(CGFloat(display.height) * pixelScale)
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        // по умолчанию курсор рисует система поверх эффекта: попав внутрь кадра, он отстаёт
        // на всю задержку пайплайна и читается как лаг мыши
        configuration.showsCursor = showsCursor
        configuration.queueDepth = 3
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(framesPerSecond))

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        try await stream.startCapture()
        self.stream = stream

        Log.capture.info(
            "captured stream started: \(configuration.width)x\(configuration.height) at \(framesPerSecond) fps"
        )
    }

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
