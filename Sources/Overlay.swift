import AppKit
import MetalKit

/// рисует статичный кадр эффекта уровня 2: ничего не захватывает, только накладывает сверху
final class OverlayRenderer {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState

    init() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal недоступен на этой машине")
        }
        guard let queue = device.makeCommandQueue() else {
            fatalError("не удалось создать MTLCommandQueue")
        }
        guard let library = device.makeDefaultLibrary() else {
            fatalError("в бандле нет default.metallib, шейдер не собран")
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "overlay_vertex")
        descriptor.fragmentFunction = library.makeFunction(name: "overlay_fragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm

        do {
            self.pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            fatalError("не удалось собрать пайплайн оверлея: \(error)")
        }
        self.device = device
        self.queue = queue
    }

    func draw(in layer: CAMetalLayer, scale: CGFloat) {
        guard let drawable = layer.nextDrawable(),
              let buffer = queue.makeCommandBuffer() else { return }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)

        guard let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setRenderPipelineState(pipeline)
        var scaleValue = Float(scale)
        encoder.setFragmentBytes(&scaleValue, length: MemoryLayout<Float>.size, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()

        buffer.present(drawable)
        buffer.commit()
    }
}

/// вью с CAMetalLayer в качестве backing layer, перерисовывается только при смене геометрии
final class OverlayView: NSView {
    private let renderer: OverlayRenderer

    init(renderer: OverlayRenderer) {
        self.renderer = renderer
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("не используется")
    }

    override func makeBackingLayer() -> CALayer {
        let layer = CAMetalLayer()
        layer.device = renderer.device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = true
        layer.isOpaque = false
        return layer
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        render()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        render()
    }

    func render() {
        guard let layer = layer as? CAMetalLayer, let scale = window?.backingScaleFactor else { return }
        layer.contentsScale = scale
        layer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        renderer.draw(in: layer, scale: scale)
    }
}

/// прозрачное окно поверх всего: клики и клавиши уходят в приложения под ним
final class OverlayWindow: NSWindow {
    init(screen: NSScreen, renderer: OverlayRenderer) {
        super.init(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        // выше меню-бара и Dock
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)))
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        // исключает оверлей из чужого захвата экрана, заранее снимает петлю обратной связи уровня 3
        sharingType = .none
        contentView = OverlayView(renderer: renderer)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// показывает и убирает оверлей, следит за сменой параметров экрана
final class OverlayController {
    private let renderer = OverlayRenderer()
    private var window: OverlayWindow?

    init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersDidChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    func setVisible(_ visible: Bool) {
        if visible {
            show()
        } else {
            window?.orderOut(nil)
            window = nil
        }
    }

    private func show() {
        guard let screen = NSScreen.screens.first else { return }
        let window = self.window ?? OverlayWindow(screen: screen, renderer: renderer)
        window.setFrame(screen.frame, display: true)
        window.orderFrontRegardless()
        (window.contentView as? OverlayView)?.render()
        self.window = window
    }

    @objc private func screenParametersDidChange() {
        guard window != nil else { return }
        show()
    }
}
