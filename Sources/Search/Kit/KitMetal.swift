import AppKit
import Metal
import QuartzCore
import simd

struct KitUniforms {
    var size: SIMD2<Swift.Float> = .zero
    var time: Swift.Float = 0
    var scale: Swift.Float = 1
    var tint: SIMD4<Swift.Float> = .zero
}

enum KitMetal {
    static let device = MTLCreateSystemDefaultDevice()
    static let queue = device?.makeCommandQueue()
    private static var pipelines: [String: MTLRenderPipelineState] = [:]

    static let prelude = """
    #include <metal_stdlib>
    using namespace metal;
    struct KitOut { float4 position [[position]]; float2 uv; };
    struct KitUniforms { float2 size; float time; float scale; float4 tint; };
    vertex KitOut kitVertex(uint id [[vertex_id]]) {
        float2 p = float2((id << 1) & 2, id & 2);
        KitOut o;
        o.position = float4(p * 2 - 1, 0, 1);
        o.uv = float2(p.x, 1 - p.y);
        return o;
    }
    """

    static func pipeline(_ source: String, format: MTLPixelFormat = .bgra8Unorm) -> MTLRenderPipelineState? {
        let key = "\(format.rawValue)|\(source)"
        if let known = pipelines[key] { return known }
        guard let device, let library = try? device.makeLibrary(source: prelude + "\n" + source, options: nil),
              let vertex = library.makeFunction(name: "kitVertex"),
              let fragment = library.makeFunction(name: "kitEffect") else { return nil }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        let attachment = descriptor.colorAttachments[0]!
        attachment.pixelFormat = format
        attachment.isBlendingEnabled = true
        attachment.sourceRGBBlendFactor = .one
        attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        attachment.sourceAlphaBlendFactor = .one
        attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        guard let made = try? device.makeRenderPipelineState(descriptor: descriptor) else { return nil }
        pipelines[key] = made
        return made
    }

    static func encode(_ pipeline: MTLRenderPipelineState, into texture: MTLTexture, uniforms: KitUniforms,
                       buffer: MTLCommandBuffer) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        var values = uniforms
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&values, length: MemoryLayout<KitUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }

    static func pixels(_ source: String, width: Int, height: Int, uniforms: KitUniforms = KitUniforms()) -> [UInt8]? {
        guard let device, let queue, let pipeline = pipeline(source) else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor), let buffer = queue.makeCommandBuffer() else { return nil }
        var values = uniforms
        values.size = SIMD2(Swift.Float(width), Swift.Float(height))
        encode(pipeline, into: texture, uniforms: values, buffer: buffer)
        buffer.commit()
        buffer.waitUntilCompleted()
        var out = [UInt8](repeating: 0, count: width * height * 4)
        texture.getBytes(&out, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        return out
    }
}

class KitMetalView: NSView {
    let source: String
    var tint: NSColor = .clear { didSet { if tint != oldValue { redraw() } } }
    var animating = false { didSet { if animating != oldValue { clock() } } }
    private(set) var frames = 0

    private var link: CADisplayLink?
    private var began = CACurrentMediaTime()
    private var pending = false
    private var metal: CAMetalLayer? { layer as? CAMetalLayer }

    init(source: String) {
        self.source = source
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func makeBackingLayer() -> CALayer {
        let made = CAMetalLayer()
        made.device = KitMetal.device
        made.pixelFormat = .bgra8Unorm
        made.framebufferOnly = true
        made.isOpaque = false
        return made
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        clock()
        fit()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        fit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        redraw()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        fit()
    }

    func redraw() {
        guard !pending else { return }
        pending = true
        RunLoop.main.perform(inModes: [.common]) { [weak self] in
            guard let self else { return }
            pending = false
            render()
        }
    }

    private func fit() {
        guard let metal else { return }
        let scale = window?.backingScaleFactor ?? 2
        let size = CGSize(width: max(1, (bounds.width * scale).rounded()), height: max(1, (bounds.height * scale).rounded()))
        if metal.contentsScale != scale { metal.contentsScale = scale }
        if metal.drawableSize != size { metal.drawableSize = size }
        redraw()
    }

    @objc private func step(_ link: CADisplayLink) { render() }

    private func clock() {
        link?.invalidate()
        link = nil
        guard animating, window != nil, !Motion.reduced else { return }
        began = CACurrentMediaTime()
        let made = displayLink(target: self, selector: #selector(step(_:)))
        made.add(to: .main, forMode: .common)
        link = made
    }

    private func render() {
        guard window != nil, bounds.width > 0, bounds.height > 0, let metal, let queue = KitMetal.queue,
              let pipeline = KitMetal.pipeline(source, format: metal.pixelFormat),
              let drawable = metal.nextDrawable(), let buffer = queue.makeCommandBuffer() else { return }
        let scale = Swift.Float(metal.contentsScale)
        let resolved = tint.kitResolved(dark: kitDark).usingColorSpace(.sRGB) ?? .clear
        let uniforms = KitUniforms(size: SIMD2(Swift.Float(metal.drawableSize.width), Swift.Float(metal.drawableSize.height)),
                                   time: Swift.Float(CACurrentMediaTime() - began), scale: scale,
                                   tint: SIMD4(Swift.Float(resolved.redComponent), Swift.Float(resolved.greenComponent),
                                               Swift.Float(resolved.blueComponent), Swift.Float(resolved.alphaComponent)))
        KitMetal.encode(pipeline, into: drawable.texture, uniforms: uniforms, buffer: buffer)
        buffer.present(drawable)
        buffer.commit()
        frames += 1
    }
}
