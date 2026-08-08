import AppKit
import Metal
import QuartzCore

enum RenderError: LocalizedError {
    case metalUnavailable
    case commandQueueUnavailable
    case noDisplay

    var errorDescription: String? {
        switch self {
        case .metalUnavailable:
            return String(localized: "this machine has no Metal device")
        case .commandQueueUnavailable:
            return String(localized: "could not create a Metal command queue")
        case .noDisplay:
            return String(localized: "the selected display is not connected")
        }
    }
}

/// рисует кадр эффекта уровня 2: ничего не захватывает, только накладывает сверху
final class OverlayRenderer {
    let device: MTLDevice
    private let queue: MTLCommandQueue

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw RenderError.metalUnavailable
        }
        guard let queue = device.makeCommandQueue() else {
            throw RenderError.commandQueueUnavailable
        }
        self.device = device
        self.queue = queue
    }

    func draw(
        in layer: CAMetalLayer,
        pipeline: MTLRenderPipelineState,
        uniforms: Uniforms,
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
        var uniforms = uniforms
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
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
    /// какой кусок кадра дисплея показывает этот оверлей, в долях от кадра
    var sourceRect = CGRect(x: 0, y: 0, width: 1, height: 1)
    /// уровень 3 рисует только по кадру захвата: без него шейдер прочитал бы пустую
    /// текстуру и выдал чёрный кадр между настоящими
    var expectsSource = false

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
              let scale = window?.backingScaleFactor,
              source != nil || !expectsSource else { return }

        // переприсваивание размера пересобирает пул drawable, поэтому только при изменении
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        if layer.drawableSize != size {
            layer.contentsScale = scale
            layer.drawableSize = size
        }
        renderer.draw(
            in: layer,
            pipeline: pipeline,
            uniforms: uniforms(
                resolution: layer.drawableSize,
                scale: scale,
                time: time,
                sourceRect: sourceRect,
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

/// то, чем был запущен захват: хранится, чтобы пережить смену разрешения и сон экрана
private struct CaptureRequest {
    let plugin: ShaderPlugin
    let parameters: [Float]
    let displayID: CGDirectDisplayID
    let frame: CGRect
    let showsCursor: Bool
    let quality: CaptureQuality
    let onStop: @MainActor @Sendable (Error) -> Void

    func with(frame: CGRect) -> CaptureRequest {
        CaptureRequest(
            plugin: plugin,
            parameters: parameters,
            displayID: displayID,
            frame: frame,
            showsCursor: showsCursor,
            quality: quality,
            onStop: onStop
        )
    }
}

/// то в дисплее, что задаётся при старте потока и не меняется на лету
private struct DisplayProfile: Equatable {
    let size: CGSize
    let scale: CGFloat
    let framesPerSecond: Int
}

/// собранный, но ещё не запущенный поток захвата вместе с параметрами дисплея
private struct CaptureSetup {
    let controller: CaptureController
    let profile: DisplayProfile
}

/// доставляет кадры с очереди захвата на главный поток.
/// отдельный тип, потому что колбэк ScreenCaptureKit приходит вне главного потока,
/// а вью изолировано главным актором
private final class FrameSink: @unchecked Sendable {
    private weak var view: OverlayView?

    init(view: OverlayView) {
        self.view = view
    }

    func deliver(_ frame: CapturedFrame) {
        // ponytail: без пропуска кадров. рисование одного треугольника дешевле
        // кадра дисплея, начнёт отставать - появится флаг занятости.
        // frame захватывается замыканием целиком: его буферы должны дожить до отрисовки.
        // assumeIsolated вместо Task: очередь главного потока сохраняет порядок кадров
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                self.view?.render(source: frame.texture)
            }
        }
    }
}

/// показывает и убирает оверлей, компилирует шейдеры и гоняет анимацию.
/// живёт на главном акторе: трогает окно, вью и display link
@MainActor
final class OverlayController {
    /// ключ включает исходник: правка shader.metal на диске должна давать новый пайплайн,
    /// иначе изменения не видно до перезапуска приложения
    private struct PipelineKey: Hashable {
        let identifier: String
        let source: String
    }

    private var cachedRenderer: OverlayRenderer?
    private var window: OverlayWindow?
    private var pipelines: [PipelineKey: MTLRenderPipelineState] = [:]
    private var displayLink: CADisplayLink?
    private var startTime: CFTimeInterval = 0
    private var currentPlugin: ShaderPlugin?
    private var currentDisplayID: CGDirectDisplayID = CGMainDisplayID()
    private var capture: CaptureController?
    private var captureRequest: CaptureRequest?
    private var captureProfile: DisplayProfile?
    /// экран спит или система уходит в сон: рисовать некуда, а батарею жалко
    private var isPaused = false

    init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersDidChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.willSleepNotification] {
            workspace.addObserver(self, selector: #selector(pause), name: name, object: nil)
        }
        for name in [NSWorkspace.screensDidWakeNotification, NSWorkspace.didWakeNotification] {
            workspace.addObserver(self, selector: #selector(resume), name: name, object: nil)
        }
        // системная настройка «уменьшать движение» касается нас напрямую: анимированные
        // пресеты это мигание и шум на весь экран
        workspace.addObserver(
            self,
            selector: #selector(reduceMotionDidChange),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(powerStateDidChange),
            name: .NSProcessInfoPowerStateDidChange,
            object: nil
        )
    }

    func show(
        plugin: ShaderPlugin,
        parameters: [Float],
        displayID: CGDirectDisplayID,
        frame: CGRect
    ) throws {
        stopCapture()
        let view = try prepareWindow(
            for: plugin,
            parameters: parameters,
            displayID: displayID,
            frame: frame
        )
        view.render(source: nil)
        setAnimating(plugin.isAnimated)
    }

    /// окно под эффектом переехало или изменило размер
    func updateFrame(_ frame: CGRect) {
        guard let window, let view = window.contentView as? OverlayView,
              let target = screen(for: currentDisplayID) else { return }
        window.setFrame(frame, display: true)
        view.sourceRect = sourceRect(for: frame, on: target)
        if !isTicking, capture == nil {
            view.render(source: nil)
        }
    }

    /// правка слайдера в настройках доезжает до работающего эффекта без перезапуска
    func updateParameters(_ values: [Float]) {
        guard let view = window?.contentView as? OverlayView else { return }
        view.parameters = values
        // анимированный пресет и захват перерисуются сами со следующим кадром
        if !isTicking, capture == nil {
            view.render(source: nil)
        }
    }

    /// уровень 3: окно поднимается до старта потока, чтобы попасть в список исключений
    /// SCContentFilter. кадры приходят с очереди захвата и рисуются на главной
    func showCapture(
        plugin: ShaderPlugin,
        parameters: [Float],
        displayID: CGDirectDisplayID,
        frame: CGRect,
        showsCursor: Bool,
        quality: CaptureQuality,
        onStop: @escaping @MainActor @Sendable (Error) -> Void
    ) async throws {
        let request = CaptureRequest(
            plugin: plugin,
            parameters: parameters,
            displayID: displayID,
            frame: frame,
            showsCursor: showsCursor,
            quality: quality,
            onStop: onStop
        )
        let setup = try prepareCapture(request)
        try await start(setup, for: request)
        capture = setup.controller
        captureRequest = request
        captureProfile = setup.profile
    }

    func hide() {
        setAnimating(false)
        stopCapture()
        captureRequest = nil
        window?.orderOut(nil)
        window = nil
        currentPlugin = nil
    }

    /// пресеты пропали с диска: их скомпилированные пайплайны больше не нужны
    func forgetPipelines(keeping identifiers: Set<String>) {
        pipelines = pipelines.filter { identifiers.contains($0.key.identifier) }
    }

    /// главный поток: поднимает окно под эффект и собирает поток захвата, но не стартует его
    private func prepareCapture(_ request: CaptureRequest) throws -> CaptureSetup {
        stopCapture()
        let view = try prepareWindow(
            for: request.plugin,
            parameters: request.parameters,
            displayID: request.displayID,
            frame: request.frame
        )
        guard let profile = displayProfile(request.displayID) else {
            throw RenderError.noDisplay
        }
        let sink = FrameSink(view: view)
        let controller = try CaptureController(
            device: try renderer().device,
            onFrame: { sink.deliver($0) },
            onStop: request.onStop
        )
        return CaptureSetup(controller: controller, profile: profile)
    }

    private func start(_ setup: CaptureSetup, for request: CaptureRequest) async throws {
        try await setup.controller.start(
            displayID: request.displayID,
            scale: setup.profile.scale,
            framesPerSecond: setup.profile.framesPerSecond,
            showsCursor: request.showsCursor,
            quality: request.quality
        )
    }

    private func displayProfile(_ displayID: CGDirectDisplayID) -> DisplayProfile? {
        guard let target = screen(for: displayID) else { return nil }
        return DisplayProfile(
            size: target.frame.size,
            scale: target.backingScaleFactor,
            framesPerSecond: target.maximumFramesPerSecond
        )
    }

    private func stopCapture() {
        capture?.stop()
        capture = nil
    }

    /// перезапуск потока под новую геометрию или после сна: разрешение дисплея могло
    /// смениться, а конфигурация SCStream задаётся один раз при старте
    private func restartCapture() {
        guard let captureRequest, !isPaused else { return }
        let request = captureRequest.with(frame: window?.frame ?? captureRequest.frame)
        Task {
            do {
                let setup = try prepareCapture(request)
                try await start(setup, for: request)
                capture = setup.controller
                self.captureRequest = request
                captureProfile = setup.profile
            } catch {
                Log.capture.error("could not restart capture: \(error.localizedDescription)")
                request.onStop(error)
            }
        }
    }

    private func renderer() throws -> OverlayRenderer {
        if let cachedRenderer {
            return cachedRenderer
        }
        let renderer = try OverlayRenderer()
        cachedRenderer = renderer
        return renderer
    }

    private func prepareWindow(
        for plugin: ShaderPlugin,
        parameters: [Float],
        displayID: CGDirectDisplayID,
        frame: CGRect
    ) throws -> OverlayView {
        let renderer = try renderer()
        let pipeline = try cachedPipeline(for: plugin)
        currentPlugin = plugin
        currentDisplayID = displayID

        guard let target = screen(for: displayID) else {
            throw RenderError.noDisplay
        }
        let window = self.window ?? OverlayWindow(screen: target, renderer: renderer)
        window.setFrame(frame, display: true)

        guard let view = window.contentView as? OverlayView else {
            throw RenderError.metalUnavailable
        }
        view.pipeline = pipeline
        view.parameters = parameters
        view.sourceRect = sourceRect(for: frame, on: target)
        view.expectsSource = plugin.manifest.level == .capture
        view.time = 0

        window.orderFrontRegardless()
        self.window = window
        startTime = CACurrentMediaTime()
        return view
    }

    private func cachedPipeline(for plugin: ShaderPlugin) throws -> MTLRenderPipelineState {
        let source: String
        switch plugin.kind {
        case let .overlay(text), let .capture(text):
            source = text
        case .gamma:
            throw PluginError.unsupportedLevel(plugin: plugin.manifest.name, level: .gammaLUT)
        }

        let key = PipelineKey(identifier: plugin.identifier, source: source)
        if let cached = pipelines[key] {
            return cached
        }
        let pipeline = try makePipeline(device: try renderer().device, plugin: plugin)
        // прежняя редакция того же плагина больше не нужна
        pipelines = pipelines.filter { $0.key.identifier != plugin.identifier }
        pipelines[key] = pipeline
        return pipeline
    }

    // MARK: - тики анимации

    private var isTicking: Bool { displayLink != nil }

    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// display link берётся у вью, поэтому такт приходит с частотой того дисплея,
    /// на котором лежит оверлей, а не с частоты главного
    private func setAnimating(_ animating: Bool) {
        stopTicking()
        guard animating, !isPaused, !reduceMotion, let view = window?.contentView else { return }

        // режим энергосбережения означает, что человек считает проценты батареи,
        // а не кадры ретро-эффекта
        let framesPerSecond: Float = ProcessInfo.processInfo.isLowPowerModeEnabled ? 30 : 60
        let link = view.displayLink(target: self, selector: #selector(tick))
        link.preferredFrameRateRange = CAFrameRateRange(
            minimum: framesPerSecond / 2,
            maximum: framesPerSecond,
            preferred: framesPerSecond
        )
        // .common, иначе анимация встаёт на время открытого меню
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopTicking() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func tick() {
        guard let view = window?.contentView as? OverlayView else { return }
        view.time = CACurrentMediaTime() - startTime
        view.render(source: nil)
    }

    // MARK: - реакции на систему

    @objc private func screenParametersDidChange() {
        guard let window, let target = screen(for: currentDisplayID) else { return }
        // рамку окна под эффектом пересчитает трекер, здесь только полноэкранный случай
        if window.frame.size == target.frame.size {
            window.setFrame(target.frame, display: true)
            (window.contentView as? OverlayView)?.render(source: nil)
        }
        // нотификация приходит и на появление иконки в Dock, и на подключение мыши,
        // а перезапуск потока нужен, только если сменилось то, что задано в его конфигурации
        guard let captureRequest,
              displayProfile(captureRequest.displayID) != captureProfile else { return }
        restartCapture()
    }

    @objc private func pause() {
        guard !isPaused, currentPlugin != nil else { return }
        isPaused = true
        stopTicking()
        stopCapture()
    }

    @objc private func resume() {
        guard isPaused else { return }
        isPaused = false
        setAnimating(currentPlugin?.isAnimated ?? false)
        restartCapture()
    }

    @objc private func reduceMotionDidChange() {
        setAnimating(currentPlugin?.isAnimated ?? false)
    }

    /// вошли или вышли из энергосбережения: частота задаётся при запуске и анимации,
    /// и захвата, поэтому пересобираем оба
    @objc private func powerStateDidChange() {
        setAnimating(currentPlugin?.isAnimated ?? false)
        guard captureRequest != nil else { return }
        restartCapture()
    }
}
