import AppKit
import Metal
import QuartzCore

/// рисует кадр эффекта уровня 2: ничего не захватывает, только накладывает сверху
final class OverlayRenderer {
    let device: MTLDevice
    private let queue: MTLCommandQueue

    init() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal недоступен на этой машине")
        }
        guard let queue = device.makeCommandQueue() else {
            fatalError("не удалось создать MTLCommandQueue")
        }
        self.device = device
        self.queue = queue
    }

    func draw(
        in layer: CAMetalLayer,
        pipeline: MTLRenderPipelineState,
        uniforms: [Float],
        source: MTLTexture?
    ) {
        guard let drawable = layer.nextDrawable(),
              let buffer = queue.makeCommandBuffer() else { return }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)

        guard let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(
            uniforms,
            length: MemoryLayout<Float>.size * uniforms.count,
            index: 0
        )
        if let source {
            encoder.setFragmentTexture(source, index: 0)
        }
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()

        buffer.present(drawable)
        buffer.commit()
    }
}

/// вью с CAMetalLayer в качестве backing layer: статичный шейдер перерисовывается
/// только при смене геометрии, анимированный гоняет контроллер
final class OverlayView: NSView {
    private let renderer: OverlayRenderer

    var pipeline: MTLRenderPipelineState?
    var parameters: [Float] = []
    var time: Double = 0

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
        render(source: nil)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        render(source: nil)
    }

    func render(source: MTLTexture?) {
        guard let layer = layer as? CAMetalLayer,
              let pipeline,
              let scale = window?.backingScaleFactor else { return }

        layer.contentsScale = scale
        layer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        renderer.draw(
            in: layer,
            pipeline: pipeline,
            uniforms: uniformValues(
                resolution: layer.drawableSize,
                scale: scale,
                time: time,
                parameters: parameters
            ),
            source: source
        )
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

/// показывает и убирает оверлей, компилирует шейдеры и гоняет анимацию
final class OverlayController {
    private let renderer = OverlayRenderer()
    private var window: OverlayWindow?
    private var pipelines: [String: MTLRenderPipelineState] = [:]
    private var timer: Timer?
    private var startTime: CFTimeInterval = 0
    private var currentPlugin: ShaderPlugin?
    private var currentDisplayID: CGDirectDisplayID = CGMainDisplayID()
    private var capture: CaptureController?

    init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersDidChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    func show(plugin: ShaderPlugin, parameters: [Float], displayID: CGDirectDisplayID) throws {
        let view = try prepareWindow(for: plugin, parameters: parameters, displayID: displayID)
        view.render(source: nil)
        setAnimating(plugin.isAnimated)
    }

    /// правка слайдера в настройках доезжает до работающего эффекта без перезапуска
    func updateParameters(_ values: [Float]) {
        guard let view = window?.contentView as? OverlayView else { return }
        view.parameters = values
        // анимированный пресет и захват перерисуются сами со следующим кадром
        if timer == nil, capture == nil {
            view.render(source: nil)
        }
    }

    /// уровень 3: окно поднимается до старта потока, чтобы попасть в список исключений
    /// SCContentFilter. кадры приходят с очереди захвата и рисуются на главной
    func showCapture(
        plugin: ShaderPlugin,
        parameters: [Float],
        displayID: CGDirectDisplayID,
        showsCursor: Bool,
        onStop: @escaping (Error) -> Void
    ) async throws {
        // async-функция без изоляции исполняется вне главного потока, а NSWindow и NSScreen
        // допустимы только на нём
        let (scale, framesPerSecond) = try await MainActor.run { () -> (CGFloat, Int) in
            _ = try prepareWindow(for: plugin, parameters: parameters, displayID: displayID)
            let target = screen(for: displayID)
            return (target?.backingScaleFactor ?? 2, target?.maximumFramesPerSecond ?? 60)
        }

        let capture = CaptureController(
            device: renderer.device,
            onFrame: { [weak self] texture in
                // ponytail: без пропуска кадров. рисование одного треугольника дешевле
                // кадра дисплея, начнёт отставать - появится флаг занятости
                DispatchQueue.main.async {
                    guard let view = self?.window?.contentView as? OverlayView else { return }
                    view.render(source: texture)
                }
            },
            onStop: onStop
        )
        try await capture.start(
            displayID: displayID,
            scale: scale,
            framesPerSecond: framesPerSecond,
            showsCursor: showsCursor
        )
        self.capture = capture
    }

    func hide() {
        setAnimating(false)
        capture?.stop()
        capture = nil
        window?.orderOut(nil)
        window = nil
        currentPlugin = nil
    }

    private func prepareWindow(
        for plugin: ShaderPlugin,
        parameters: [Float],
        displayID: CGDirectDisplayID
    ) throws -> OverlayView {
        let pipeline = try cachedPipeline(for: plugin)
        currentPlugin = plugin
        currentDisplayID = displayID

        guard let target = screen(for: displayID) else {
            throw CaptureError.noDisplay
        }
        let window = self.window ?? OverlayWindow(screen: target, renderer: renderer)
        window.setFrame(target.frame, display: true)

        guard let view = window.contentView as? OverlayView else {
            fatalError("у оверлейного окна не тот contentView")
        }
        view.pipeline = pipeline
        view.parameters = parameters
        view.time = 0

        window.orderFrontRegardless()
        self.window = window
        startTime = CACurrentMediaTime()
        return view
    }

    private func cachedPipeline(for plugin: ShaderPlugin) throws -> MTLRenderPipelineState {
        if let cached = pipelines[plugin.identifier] {
            return cached
        }
        let pipeline = try makePipeline(device: renderer.device, plugin: plugin)
        pipelines[plugin.identifier] = pipeline
        return pipeline
    }

    // ponytail: обычный таймер вместо синхронизации с vsync. дрожание кадра на шуме
    // и полосах незаметно, а CAMetalDisplayLink требует macOS 14 при цели 13
    private func setAnimating(_ animating: Bool) {
        timer?.invalidate()
        timer = nil
        guard animating else { return }

        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self, let view = self.window?.contentView as? OverlayView else { return }
            view.time = CACurrentMediaTime() - self.startTime
            view.render(source: nil)
        }
        // .common, иначе анимация встаёт на время открытого меню
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    @objc private func screenParametersDidChange() {
        guard let window, let target = screen(for: currentDisplayID) else { return }
        window.setFrame(target.frame, display: true)
        (window.contentView as? OverlayView)?.render(source: nil)
    }
}
