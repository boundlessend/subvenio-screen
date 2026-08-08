import AppKit
import Metal
import MetalKit
import SwiftUI

/// картинка, на которой крутится превью. встроенный образец, а не экран пользователя:
/// иначе окно настроек требовало бы разрешения на запись экрана ради одной миниатюры
private func previewSample() -> CGImage? {
    guard let image = NSImage(named: "PreviewSample") else { return nil }
    return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
}

/// уровень 1 живёт в scanout, поэтому в превью его приходится посчитать самим:
/// та же таблица, но применённая к пикселям образца
func gammaPreviewImage(_ settings: GammaSettings, source: CGImage) -> CGImage? {
    let width = source.width
    let height = source.height
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(
              data: nil,
              width: width,
              height: height,
              bitsPerComponent: 8,
              bytesPerRow: width * 4,
              space: space,
              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
          ) else { return nil }

    context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
    guard let data = context.data else { return nil }

    let tables = gammaTables(settings, size: 256)
    let lookup = [tables.red, tables.green, tables.blue].map { table in
        table.map { UInt8(min(max($0, 0), 1) * 255) }
    }
    let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
    for offset in stride(from: 0, to: width * height * 4, by: 4) {
        for channel in 0..<3 {
            pixels[offset + channel] = lookup[channel][Int(pixels[offset + channel])]
        }
    }
    return context.makeImage()
}

/// правка пресета на диске не меняет его идентификатор, поэтому пересобирать превью
/// приходится по содержимому: иначе шейдер и гамма-таблица остались бы прежними
private func previewSignature(_ plugin: ShaderPlugin) -> String {
    switch plugin.kind {
    case let .gamma(settings):
        return "\(plugin.identifier)|\(settings.tint)|\(settings.gamma)|\(settings.invert)|\(settings.blackPoint)|\(settings.whitePoint)"
    case let .overlay(source), let .capture(source):
        return "\(plugin.identifier)|\(source.hashValue)"
    }
}

/// показывает выбранный пресет на образце: уровень 1 пересчитанной картинкой,
/// уровни 2 и 3 тем же шейдером и тем же слоем Metal, что и настоящий эффект
final class PreviewView: NSView {
    /// один рендерер на все превью: девайс и очередь команд не зависят от пресета
    private static let renderer = try? OverlayRenderer()
    /// превью маленькое, поэтому половина частоты дисплея незаметна, а стоит вдвое дешевле
    private static let framesPerSecond: Float = 30

    private let metalLayer = CAMetalLayer()
    private let sample = previewSample()
    private var pipeline: MTLRenderPipelineState?
    private var sampleTexture: MTLTexture?
    private var plugin: ShaderPlugin?
    private var signature = ""
    private var parameters: [Float] = []
    private var tickLink: CADisplayLink?
    private var startTime = CACurrentMediaTime()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        metalLayer.device = Self.renderer?.device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.isOpaque = false
        metalLayer.isHidden = true

        layer?.cornerRadius = 6
        layer?.masksToBounds = true
        layer?.contentsGravity = .resizeAspectFill
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(metalLayer)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(occlusionDidChange),
            name: NSWindow.didChangeOcclusionStateNotification,
            object: nil
        )
        // окно, целиком закрытое чужим приложением, macOS занятым не считает,
        // поэтому уход из активных это второй признак того, что на превью никто не смотрит
        for name: NSNotification.Name in [
            NSApplication.didResignActiveNotification,
            NSApplication.didBecomeActiveNotification
        ] {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(activationDidChange),
                name: name,
                object: nil
            )
        }
    }

    required init?(coder: NSCoder) {
        fatalError("не используется")
    }

    /// сменился пресет или значения слайдеров
    func show(plugin: ShaderPlugin, parameters: [Float]) {
        self.parameters = parameters
        let signature = previewSignature(plugin)
        if signature != self.signature {
            self.signature = signature
            self.plugin = plugin
            startTime = CACurrentMediaTime()
            rebuild(for: plugin)
        }
        setAnimating(plugin.isAnimated)
        render()
    }

    /// уровень 1 рисуется прямо в фоновый слой, уровни 2 и 3 поверх образца шейдером
    private func rebuild(for plugin: ShaderPlugin) {
        guard let sample else { return }
        switch plugin.kind {
        case let .gamma(settings):
            pipeline = nil
            metalLayer.isHidden = true
            layer?.contents = gammaPreviewImage(settings, source: sample) ?? sample
        case .overlay, .capture:
            layer?.contents = sample
            pipeline = makePreviewPipeline(for: plugin)
            metalLayer.isHidden = pipeline == nil
        }
    }

    /// битый пользовательский шейдер не должен ронять окно настроек: превью остаётся
    /// чистым образцом, а текст ошибки человек увидит при попытке включить эффект
    private func makePreviewPipeline(for plugin: ShaderPlugin) -> MTLRenderPipelineState? {
        guard let device = Self.renderer?.device else { return nil }
        do {
            return try makePipeline(device: device, plugin: plugin)
        } catch {
            Log.overlay.error("preview pipeline failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// уровень 3 читает картинку под собой, поэтому образец нужен ему текстурой.
    /// SRGB выключен: захват тоже приходит в линейном bgra8Unorm, и шейдер должен
    /// видеть в превью те же числа, что и на экране
    private func texture(for device: MTLDevice) -> MTLTexture? {
        if let sampleTexture {
            return sampleTexture
        }
        guard let sample else { return nil }
        sampleTexture = try? MTKTextureLoader(device: device).newTexture(
            cgImage: sample,
            options: [.SRGB: NSNumber(value: false)]
        )
        return sampleTexture
    }

    override func layout() {
        super.layout()
        // слой добавлен вручную и в autoresizing не участвует
        metalLayer.frame = bounds
        render()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        render()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        setAnimating(plugin?.isAnimated ?? false)
        render()
    }

    private func render() {
        guard let plugin, plugin.manifest.level != .gammaLUT,
              let renderer = Self.renderer,
              let pipeline,
              let scale = window?.backingScaleFactor,
              bounds.width > 0, bounds.height > 0 else { return }

        renderer.draw(
            in: metalLayer,
            pipeline: pipeline,
            size: bounds.size,
            scale: scale,
            time: CACurrentMediaTime() - startTime,
            sourceRect: CGRect(x: 0, y: 0, width: 1, height: 1),
            parameters: parameters,
            source: plugin.manifest.level == .capture ? texture(for: renderer.device) : nil
        )
    }

    // MARK: - тик

    /// анимация идёт, только пока окно настроек открыто и видно: за чужим окном
    /// превью крутилось бы вхолостую. состояние сверяется, потому что обновление
    /// приходит на каждое движение ползунка
    private func setAnimating(_ animating: Bool) {
        let wanted = animating
            && NSApp.isActive
            && window?.occlusionState.contains(.visible) == true
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard wanted != (tickLink != nil) else { return }

        tickLink?.invalidate()
        tickLink = nil
        guard wanted else { return }

        tickLink = startDisplayLink(
            on: self,
            target: self,
            selector: #selector(tick),
            framesPerSecond: Self.framesPerSecond
        )
    }

    @objc private func tick() {
        render()
    }

    @objc private func occlusionDidChange(_ notification: Notification) {
        guard let changed = notification.object as? NSWindow, changed == window else { return }
        setAnimating(plugin?.isAnimated ?? false)
    }

    @objc private func activationDidChange() {
        setAnimating(plugin?.isAnimated ?? false)
    }
}

/// превью в окне настроек: обновляется, когда меняется пресет или значения слайдеров
struct EffectPreview: NSViewRepresentable {
    let plugin: ShaderPlugin
    let parameters: [Float]

    func makeNSView(context: Context) -> PreviewView {
        let view = PreviewView(frame: .zero)
        view.show(plugin: plugin, parameters: parameters)
        return view
    }

    func updateNSView(_ view: PreviewView, context: Context) {
        view.show(plugin: plugin, parameters: parameters)
    }
}
