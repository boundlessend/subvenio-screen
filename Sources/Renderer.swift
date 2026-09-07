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

/// рисует кадр эффекта в слой Metal: ничего не захватывает, только накладывает сверху.
/// один и тот же рендерер обслуживает оверлей на экране и превью в настройках,
/// поэтому композиция у них совпадает по построению
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

    /// подгоняет слой под размер в точках и рисует кадр.
    /// completion зовётся, когда GPU закончил работу с кадром: раньше отпускать
    /// текстуру захвата нельзя, её поверхность вернётся в пул под следующий кадр
    func draw(
        in layer: CAMetalLayer,
        pipeline: MTLRenderPipelineState,
        size: CGSize,
        scale: CGFloat,
        time: Double,
        sourceRect: CGRect,
        parameters: [Float],
        source: MTLTexture?,
        completion: @escaping @Sendable () -> Void
    ) {
        // переприсваивание размера пересобирает пул drawable, поэтому только при изменении
        let drawableSize = CGSize(width: size.width * scale, height: size.height * scale)
        if layer.drawableSize != drawableSize {
            layer.contentsScale = scale
            layer.drawableSize = drawableSize
        }
        draw(
            in: layer,
            pipeline: pipeline,
            uniforms: uniforms(
                resolution: layer.drawableSize,
                scale: scale,
                time: time,
                sourceRect: sourceRect,
                parameters: parameters
            ),
            source: source,
            completion: completion
        )
    }

    private func draw(
        in layer: CAMetalLayer,
        pipeline: MTLRenderPipelineState,
        uniforms: Uniforms,
        source: MTLTexture?,
        completion: @escaping @Sendable () -> Void
    ) {
        // autoreleasepool вокруг кадра: без него drawable живут до конца витка
        // runloop, и на нескольких слоях сразу пул упирается сам в себя
        autoreleasepool {
            guard let drawable = layer.nextDrawable(),
                  let buffer = queue.makeCommandBuffer() else {
                completion()
                return
            }

            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = drawable.texture
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)

            guard let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else {
                completion()
                return
            }
            encoder.setRenderPipelineState(pipeline)
            var uniforms = uniforms
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
            if let source {
                encoder.setFragmentTexture(source, index: 0)
            }
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()

            buffer.addCompletedHandler { _ in completion() }
            buffer.present(drawable)
            buffer.commit()
        }
    }
}

/// такт анимации приходит с частотой того дисплея, на котором лежит вью, а не главного
func startDisplayLink(
    on view: NSView,
    target: AnyObject,
    selector: Selector,
    framesPerSecond: Float
) -> CADisplayLink {
    let link = view.displayLink(target: target, selector: selector)
    link.preferredFrameRateRange = CAFrameRateRange(
        minimum: framesPerSecond / 2,
        maximum: framesPerSecond,
        preferred: framesPerSecond
    )
    // .common, иначе анимация встаёт на время открытого меню
    link.add(to: .main, forMode: .common)
    return link
}
