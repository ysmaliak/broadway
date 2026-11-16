import AppKit

enum KitGrain {
    static let density: Double = 1.0 / 28.0
    static let strength: Double = 0.6

    static let source = """
    fragment float4 kitEffect(KitOut in [[stage_in]], constant KitUniforms& u [[buffer(0)]]) {
        float2 cell = floor(in.uv * u.size / max(u.scale, 1.0));
        uint h = uint(cell.x) * 0x8da6b343u ^ uint(cell.y) * 0xd8163841u ^ 0x2545f491u;
        h ^= h >> 15;
        h *= 0x2c1b3c6du;
        h ^= h >> 12;
        h *= 0x297a2d39u;
        h ^= h >> 15;
        float chance = float(h & 0xffffu) / 65536.0;
        if (chance >= \(density)) { return float4(0); }
        float shade = ((h >> 16) & 1u) == 1u ? \(strength) : 0.0;
        return float4(shade, shade, shade, \(strength));
    }
    """

    static func view(opacity: CGFloat = 0.1, overlay: Bool = true) -> KitGrainView {
        let view = KitGrainView()
        view.alphaValue = opacity
        if overlay { view.layer?.compositingFilter = "overlayBlendMode" }
        return view
    }
}

final class KitGrainView: KitMetalView {
    init() {
        super.init(source: KitGrain.source)
        setAccessibilityElement(false)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
