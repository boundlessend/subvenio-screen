import AppKit
import CoreVideo
import Metal
import ScreenCaptureKit

enum CaptureError: LocalizedError {
    case accessDenied
    case noDisplay
    case textureCacheFailed(code: CVReturn)

    var errorDescription: String? {
        switch self {
        case .accessDenied:
            return String(localized: "no Screen Recording permission")
        case .noDisplay:
            return String(localized: "ScreenCaptureKit returned no displays")
        case let .textureCacheFailed(code):
            return String(
                format: String(localized: "could not create CVMetalTextureCache, code %lld"),
                Int(code)
            )
        }
    }
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
/// а на экран попадёт мусор
struct CapturedFrame {
    let texture: MTLTexture
    private let cvTexture: CVMetalTexture
    private let pixelBuffer: CVPixelBuffer

    init(texture: MTLTexture, cvTexture: CVMetalTexture, pixelBuffer: CVPixelBuffer) {
        self.texture = texture
        self.cvTexture = cvTexture
        self.pixelBuffer = pixelBuffer
    }
}

/// бэкенд уровня 3: захват экрана в текстуру Metal без копирования на CPU
final class CaptureController: NSObject, SCStreamOutput, SCStreamDelegate {
    private let device: MTLDevice
    private let onFrame: (CapturedFrame) -> Void
    private let onStop: (Error) -> Void

    private var stream: SCStream?
    private var textureCache: CVMetalTextureCache?
    private let sampleQueue = DispatchQueue(label: "dev.senya.ScreenFilter.capture")

    init(
        device: MTLDevice,
        onFrame: @escaping (CapturedFrame) -> Void,
        onStop: @escaping (Error) -> Void
    ) {
        self.device = device
        self.onFrame = onFrame
        self.onStop = onStop
    }

    /// масштаб и частоту передаёт вызывающий: NSScreen читается только с главного потока,
    /// а старт потока живёт вне его
    func start(
        displayID: CGDirectDisplayID,
        scale: CGFloat,
        framesPerSecond: Int,
        showsCursor: Bool
    ) async throws {
        guard hasScreenRecordingAccess() else {
            throw CaptureError.accessDenied
        }

        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        guard let display = content.displays.first(where: { $0.displayID == displayID })
            ?? content.displays.first else {
            throw CaptureError.noDisplay
        }

        // собственные окна вон из захвата, иначе кадр попадёт сам в себя и пойдёт петля.
        // вместе с sharingType = .none у оверлейного окна это закрывает вопрос с двух сторон
        let ownWindows = content.windows.filter { $0.owningApplication?.processID == getpid() }
        let filter = SCContentFilter(display: display, excludingWindows: ownWindows)

        let configuration = SCStreamConfiguration()
        configuration.width = Int(CGFloat(display.width) * scale)
        configuration.height = Int(CGFloat(display.height) * scale)
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        // по умолчанию курсор рисует система поверх эффекта: попав внутрь кадра, он отстаёт
        // на всю задержку пайплайна и читается как лаг мыши
        configuration.showsCursor = showsCursor
        configuration.queueDepth = 3
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(framesPerSecond))

        var cache: CVMetalTextureCache?
        let status = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        guard status == kCVReturnSuccess, let cache else {
            throw CaptureError.textureCacheFailed(code: status)
        }
        textureCache = cache

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() {
        guard let stream else { return }
        self.stream = nil
        textureCache = nil
        stream.stopCapture { error in
            if let error {
                NSLog("захват остановился с ошибкой: \(error.localizedDescription)")
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
              let cache = textureCache,
              isCompleteFrame(sampleBuffer) else { return }

        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            cache,
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
            NSLog("кадр не превратился в MTLTexture, код \(status)")
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

    /// сюда прилетает отзыв разрешения в системных настройках
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        self.stream = nil
        onStop(error)
    }
}
