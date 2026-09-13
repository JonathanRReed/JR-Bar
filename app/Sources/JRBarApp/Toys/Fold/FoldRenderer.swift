import AppKit
import CoreVideo
import MetalKit

enum FoldRendererError: LocalizedError {
    case noDevice

    var errorDescription: String? {
        switch self {
        case .noDevice: return "no Metal device"
        }
    }
}

/// One Metal pipeline that bends the captured desktop around the screen's
/// bottom edge (the hinge), dims it toward the top, and in Fog blurs it.
/// The shader source is a string, not a `.metal` file: the Command Line
/// Tools toolchain ships no `metal` compiler, so the library is built at
/// runtime and cached in the pipeline. A compile failure throws from
/// `init`, which the toy reports once as "Fold can't start its renderer".
final class FoldRenderer: NSObject {
    /// The three fragment weights, pre-multiplied by `fold` on the CPU so
    /// the shader sees final amounts: perspective warp always applies,
    /// dim only for Dusk & Fog, blur only for Fog with Reduce Motion off.
    struct Weights {
        var warp: Float = 0
        var dim: Float = 0
        var blur: Float = 0
    }

    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private var textureCache: CVMetalTextureCache?
    var weights = Weights()
    /// The newest captured frame, pulled by each draw.
    var frameSource: (() -> CVPixelBuffer?)?

    init(pixelFormat: MTLPixelFormat) throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw FoldRendererError.noDevice }
        self.device = device
        let library = try device.makeLibrary(source: Self.shaderSource, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "foldVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "foldFragment")
        descriptor.colorAttachments[0].pixelFormat = pixelFormat
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        guard let queue = device.makeCommandQueue() else { throw FoldRendererError.noDevice }
        self.queue = queue
        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        textureCache = cache
        super.init()
    }

    /// The fold shader: a fullscreen triangle plus a fragment that treats
    /// the screen as a plane swinging down about its bottom edge.
    private static let shaderSource = """
#include <metal_stdlib>
using namespace metal;

struct FoldWeights {
    float warp;
    float dim;
    float blur;
};

struct FoldOut {
    float4 position [[position]];
    float2 uv;
};

vertex FoldOut foldVertex(uint vid [[vertex_id]]) {
    float2 pos = float2(float((vid << 1) & 2), float(vid & 2)) * 2.0 - 1.0;
    FoldOut out;
    out.position = float4(pos, 0.0, 1.0);
    out.uv = float2(pos.x * 0.5 + 0.5, 0.5 - pos.y * 0.5);  // uv.y = 0 top, 1 bottom
    return out;
}

fragment float4 foldFragment(FoldOut in [[stage_in]],
                             texture2d<float> frame [[texture(0)]],
                             constant FoldWeights &w [[buffer(0)]]) {
    constexpr sampler sampl(filter::linear, address::clamp_to_edge, coord::normalized);
    float h = 1.0 - in.uv.y;   // 0 at the hinge (bottom), 1 at the far edge
    float tilt = clamp(w.warp, 0.0, 0.95);
    // A source row at height s lands at h = s * (1 - tilt * s) once the
    // plane tips. Invert that for the sample point; past the fold horizon
    // (disc <= 0) there is no source row at all.
    float s = h;
    float over = 0.0;
    if (tilt > 1e-4) {
        float disc = 1.0 - 4.0 * tilt * h;
        if (disc <= 0.0) {
            s = 1.0;
            over = 1.0;
        } else {
            s = (1.0 - sqrt(disc)) / (2.0 * tilt);
        }
    }
    // The far edge tips toward the viewer, so features widen with height.
    float widen = 1.0 + tilt * h * 0.9;
    float2 uv = float2(0.5 + (in.uv.x - 0.5) / widen, 1.0 - clamp(s, 0.0, 1.0));
    float4 color = frame.sample(sampl, uv);
    if (w.blur > 1e-4 && h > 0.0) {
        // Fog: a cheap radial blur whose radius grows toward the far edge.
        float r = w.blur * h * 0.02;
        float4 acc = color;
        acc += frame.sample(sampl, uv + float2(r, 0.0));
        acc += frame.sample(sampl, uv - float2(r, 0.0));
        acc += frame.sample(sampl, uv + float2(0.0, r));
        acc += frame.sample(sampl, uv - float2(0.0, r));
        acc += frame.sample(sampl, uv + float2(r * 0.7, r * 0.7));
        acc += frame.sample(sampl, uv - float2(r * 0.7, r * 0.7));
        acc += frame.sample(sampl, uv + float2(r * 0.7, -r * 0.7));
        acc += frame.sample(sampl, uv - float2(r * 0.7, -r * 0.7));
        color = acc / 9.0;
    }
    // Dusk & Fog: the folded screen sits in its own shadow toward the top.
    color.rgb *= 1.0 - clamp(w.dim * h, 0.0, 0.85);
    // Past the horizon we are looking at the back of the lid.
    color.rgb = mix(color.rgb, float3(0.02, 0.02, 0.03), over * 0.9);
    return color;
}
"""
}

extension FoldRenderer: MTKViewDelegate {
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        autoreleasepool {
            guard let pixelBuffer = frameSource?(),
                  let pass = view.currentRenderPassDescriptor,
                  let drawable = view.currentDrawable,
                  let cvTexture = textureSource(from: pixelBuffer),
                  let texture = CVMetalTextureGetTexture(cvTexture),
                  let command = queue.makeCommandBuffer(),
                  let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return }
            var weights = self.weights
            encoder.setRenderPipelineState(pipeline)
            encoder.setFragmentTexture(texture, index: 0)
            encoder.setFragmentBytes(&weights, length: MemoryLayout<Weights>.stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
            command.present(drawable)
            command.commit()
        }
    }

    /// The CVMetalTexture must outlive the encode; returning it (not the
    /// MTLTexture) keeps the backing alive until the command commits.
    private func textureSource(from pixelBuffer: CVPixelBuffer) -> CVMetalTexture? {
        guard let textureCache else { return nil }
        var out: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, pixelBuffer, nil, .bgra8Unorm,
            CVPixelBufferGetWidth(pixelBuffer), CVPixelBufferGetHeight(pixelBuffer), 0, &out)
        guard status == kCVReturnSuccess else { return nil }
        return out
    }
}
