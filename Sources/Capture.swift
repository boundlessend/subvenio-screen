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
            return "нет разрешения Screen Recording"
        case .noDisplay:
            return "ScreenCaptureKit не отдал ни одного дисплея"
        case let .textureCacheFailed(code):
            return "не удалось создать CVMetalTextureCache, код \(code)"
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

/// бэкенд уровня 3: захват экрана в текстуру Metal без копирования на CPU
final class CaptureController: NSObject, SCStreamOutput, SCStreamDelegate {
    private let device: MTLDevice
    private let onFrame: (MTLTexture) -> Void
    private let onStop: (Error) -> Void

    private var stream: SCStream?
    private var textureCache: CVMetalTextureCache?
    private let sampleQueue = DispatchQueue(label: "dev.senya.ScreenFilter.capture")

    init(device: MTLDevice, onFrame: @escaping (MTLTexture) -> Void, onStop: @escaping (Error) -> Void) {
        self.device = device
        self.onFrame = onFrame
        self.onStop = onStop
    }

    /// масштаб и частоту передаёт вызывающий: NSScreen читается только с главного потока,
    /// а старт потока живёт вне его
    func start(scale: CGFloat, framesPerSecond: Int) async throws {
        guard hasScreenRecordingAccess() else {
            throw CaptureError.accessDenied
        }

        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() })
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
        // курсор рисует система поверх эффекта: нарисованный внутри кадра отставал бы
        // на всю задержку пайплайна и читался бы как лаг мыши
        configuration.showsCursor = false
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
              let cache = textureCache else { return }

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

        onFrame(texture)
    }

    // MARK: - SCStreamDelegate

    /// сюда прилетает отзыв разрешения в системных настройках
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        self.stream = nil
        onStop(error)
    }
}
