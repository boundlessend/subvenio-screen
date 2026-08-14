import AppKit
import Metal
import QuartzCore

/// вью с CAMetalLayer в качестве backing layer: статичный шейдер перерисовывается
/// только при смене геометрии, анимированный гоняет контроллер
final class OverlayView: NSView {
    /// время шейдера идёт по кругу раз в сутки: дальше оно перестаёт помещаться
    /// во float32 без потери шага между кадрами, а скачок фазы раз в сутки не виден
    private static let timeWrap: CFTimeInterval = 86_400

    private let renderer: OverlayRenderer

    var pipeline: MTLRenderPipelineState?
    var parameters: [Float] = []
    /// анимация разрешена: время отсчитывается прямо при отрисовке. хранить момент
    /// времени в поле нельзя - кадры уровня 3 приходят со своей очереди и своего
    /// такта не имеют, и такой шейдер рисовался бы вечно на нуле
    var isAnimated = false
    var startTime = CACurrentMediaTime()
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
        // пространство задаётся явно, иначе числа шейдера читаются как координаты
        // дисплея: на Display P3 тот же тинт выходил насыщеннее задуманного,
        // и превью с экраном расходились по цвету. пресеты писались в sRGB
        layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
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

        let time = isAnimated
            ? (CACurrentMediaTime() - startTime).truncatingRemainder(dividingBy: Self.timeWrap)
            : 0
        renderer.draw(
            in: layer,
            pipeline: pipeline,
            size: bounds.size,
            scale: scale,
            time: time,
            sourceRect: sourceRect,
            parameters: parameters,
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

/// показывает и убирает оверлей, компилирует шейдеры и гоняет анимацию.
/// живёт на главном акторе: трогает окно, вью и display link
@MainActor
final class OverlayController {
    private var cachedRenderer: OverlayRenderer?
    private var window: OverlayWindow?
    private let pipelines = PipelineCache.shared
    private var displayLink: CADisplayLink?
    private var currentPlugin: ShaderPlugin?
    private var currentDisplayID: CGDirectDisplayID = CGMainDisplayID()
    /// эффект накрывает весь дисплей, а не рамку чужого окна: только такой оверлей
    /// подстраивается сам, когда у дисплея меняется разрешение или масштаб
    private var coversWholeDisplay = false
    private var capture: CaptureController?
    private var captureRequest: CaptureRequest?
    private var captureProfile: DisplayProfile?
    /// номер поколения захвата: старт уровня 3 асинхронный, и пока он идёт, эффект могли
    /// выключить или перезапустить. поток, приехавший с чужим номером, уже никому не нужен
    private var captureGeneration = 0
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
        coversWholeDisplay = frame == target.frame
        window.setFrame(frame, display: true)
        view.sourceRect = sourceRect(for: frame, in: target.frame)
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
        let generation = captureGeneration
        try await start(setup, for: request)
        guard generation == captureGeneration else {
            Log.capture.info("capture start dropped: the effect changed while it was starting")
            setup.controller.stop()
            return
        }
        capture = setup.controller
        captureRequest = request
        captureProfile = setup.profile
        // такта здесь не будет, но время шейдера должно идти: кадры захвата несут его сами
        setAnimating(plugin.isAnimated)
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
        pipelines.forget(keeping: identifiers)
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
        // старт, который сейчас идёт, доедет уже с прежним номером и остановит себя сам
        captureGeneration += 1
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
                let generation = captureGeneration
                try await start(setup, for: request)
                guard generation == captureGeneration else {
                    setup.controller.stop()
                    return
                }
                capture = setup.controller
                self.captureRequest = request
                captureProfile = setup.profile
                setAnimating(request.plugin.isAnimated)
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
        let pipeline = try pipelines.pipeline(for: plugin, device: renderer.device)
        currentPlugin = plugin
        currentDisplayID = displayID

        guard let target = screen(for: displayID) else {
            throw RenderError.noDisplay
        }
        let window = self.window ?? OverlayWindow(screen: target, renderer: renderer)
        coversWholeDisplay = frame == target.frame
        window.setFrame(frame, display: true)

        guard let view = window.contentView as? OverlayView else {
            throw RenderError.metalUnavailable
        }
        view.pipeline = pipeline
        view.parameters = parameters
        view.sourceRect = sourceRect(for: frame, in: target.frame)
        view.expectsSource = plugin.manifest.level == .capture
        view.startTime = CACurrentMediaTime()

        window.orderFrontRegardless()
        self.window = window
        Log.overlay.info(
            "overlay shown: \(plugin.identifier, privacy: .public) at \(String(describing: frame), privacy: .public), screen \(String(describing: target.frame), privacy: .public)"
        )
        return view
    }

    // MARK: - тики анимации

    private var isTicking: Bool { displayLink != nil }

    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private func setAnimating(_ animating: Bool) {
        stopTicking()
        guard let view = window?.contentView as? OverlayView else { return }
        // системная настройка «уменьшать движение» и сон экрана останавливают само
        // время шейдера, а не только такт: иначе уровень 3 продолжал бы анимировать
        // по кадрам захвата, которые приходят независимо от нас
        view.isAnimated = animating && !isPaused && !reduceMotion

        // уровень 3 перерисовывается на каждом кадре захвата и второго такта не просит:
        // тик всё равно рисовать нечем, source у него пустой
        guard view.isAnimated, capture == nil else { return }

        // режим энергосбережения означает, что человек считает проценты батареи,
        // а не кадры ретро-эффекта
        displayLink = startDisplayLink(
            on: view,
            target: self,
            selector: #selector(tick),
            framesPerSecond: ProcessInfo.processInfo.isLowPowerModeEnabled ? 30 : 60
        )
    }

    private func stopTicking() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func tick() {
        (window?.contentView as? OverlayView)?.render(source: nil)
    }

    // MARK: - реакции на систему

    @objc private func screenParametersDidChange() {
        guard let window, let target = screen(for: currentDisplayID) else { return }
        Log.overlay.info(
            "screen parameters changed: window \(String(describing: window.frame), privacy: .public), screen \(String(describing: target.frame), privacy: .public)"
        )
        // рамку окна под чужим окном пересчитает трекер, здесь только полноэкранный случай.
        // сравнивать размеры бесполезно: они расходятся ровно тогда, когда подстроиться и надо
        if coversWholeDisplay, window.frame != target.frame {
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
        Log.overlay.info("pausing: screen asleep")
        isPaused = true
        stopTicking()
        stopCapture()
    }

    @objc private func resume() {
        guard isPaused else { return }
        Log.overlay.info(
            "resuming: window \(String(describing: self.window?.frame), privacy: .public)"
        )
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
