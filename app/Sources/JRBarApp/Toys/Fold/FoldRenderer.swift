import AppKit
import CoreVideo
import MetalKit

/// A frame held alive across the GPU fence: CoreVideo buffers are
/// reference-counted and safe to retain from the completion queue.
private struct RetainedFrame: @unchecked Sendable {
    let buffer: CVPixelBuffer?
    let texture: CVMetalTexture?
}

/// A Metal object crossing a `@Sendable` completion handler. Metal
/// textures are thread-safe for encoding and sampling; the wrapper just
/// tells Swift that.
private struct SendBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

enum FoldRendererError: LocalizedError {
    case noDevice

    var errorDescription: String? {
        switch self {
        case .noDevice: return "no Metal device"
        }
    }
}

/// One Metal pipeline that draws the fold as the physical gesture it
/// is: the captured desktop is a rigid plane still standing at the
/// activation angle while the physical lid swings under it. `delta` is
/// the real lid travel in radians, so the held plane counter-rotates by
/// exactly what the hinge moved — that identity is the whole illusion.
///
/// Frames arrive as IOSurface-backed buffers and land in a private,
/// mipmapped texture via a GPU blit — the matte blur reads real mip
/// levels, so its disc stays velvet at any radius instead of speckling
/// like a sparse-tap fake. The shader source is a string, not a `.metal`
/// file: the Command Line Tools toolchain ships no `metal` compiler, so
/// the library is built at runtime and cached in the pipeline. A compile
/// failure throws from `init`, which the toy reports once as "Fold can't
/// start its renderer".
final class FoldRenderer: NSObject, @unchecked Sendable {
    /// Per-draw uniforms. `delta` is the lid's travel past the reference
    /// angle, in radians (0 at activation, clamped at 1.25).
    /// `blurStrength`/`dimStrength` carry the style, `persp` blends the
    /// parallel hold into finite-eye keystone, `samples` adapts the blur
    /// disc to the radius, and `motionBoost` (in blur-radius units) is
    /// the velocity term that keeps fast slams silky instead of stepping.
    struct Params {
        var cover: SIMD2<Float> = .init(1, 1)
        var imageSize: SIMD2<Float> = .init(1, 1)
        var delta: Float = 0
        var aspect: Float = 1.6
        var texAspect: Float = 1.6
        var blurStrength: Float = 0
        var dimStrength: Float = 0
        var persp: Float = 1
        var samples: Float = 20
        var motionBoost: Float = 0
    }

    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let sampler: MTLSamplerState
    private var textureCache: CVMetalTextureCache?
    /// The newest capture as a private mipmapped texture. Published on
    /// the main actor after the blit commits, generation-guarded so an
    /// older overlapping upload can never overwrite a newer one.
    private var desktopTexture: MTLTexture?
    private var textureGeneration: UInt64 = 0
    /// Frames in flight past two drop instead of piling up GPU work.
    private let inFlight = DispatchSemaphore(value: 2)
    var params = Params()

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
        let samplerDesc = MTLSamplerDescriptor()
        samplerDesc.minFilter = .linear
        samplerDesc.magFilter = .linear
        samplerDesc.mipFilter = .linear
        samplerDesc.sAddressMode = .clampToEdge
        samplerDesc.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: samplerDesc) else {
            throw FoldRendererError.noDevice
        }
        self.sampler = sampler
        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        textureCache = cache
        super.init()
    }

    /// The newest captured frame, pushed once per delivery. The IOSurface
    /// texture blits into a private mipmapped copy on the GPU — no CPU
    /// decode, no staging — and the finished texture publishes on the
    /// main actor so a draw can never observe a half-swapped frame.
    @discardableResult
    func setDesktopFrame(_ pixelBuffer: CVPixelBuffer) -> Bool {
        guard let textureCache else { return false }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        var wrapped: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, pixelBuffer, nil, .bgra8Unorm,
            width, height, 0, &wrapped)
        guard status == kCVReturnSuccess, let wrapped,
              let source = CVMetalTextureGetTexture(wrapped) else { return false }
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: true)
        desc.mipmapLevelCount = 3
        desc.usage = .shaderRead
        desc.storageMode = .private
        guard let texture = device.makeTexture(descriptor: desc),
              let command = queue.makeCommandBuffer(),
              let blit = command.makeBlitCommandEncoder() else { return false }
        blit.copy(from: source, sourceSlice: 0, sourceLevel: 0,
                  sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: width, height: height, depth: 1),
                  to: texture, destinationSlice: 0, destinationLevel: 0,
                  destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.generateMipmaps(for: texture)
        blit.endEncoding()
        textureGeneration &+= 1
        let generation = textureGeneration
        let retained = RetainedFrame(buffer: pixelBuffer, texture: wrapped)
        let ready = SendBox(texture)
        command.addCompletedHandler { [weak self] _ in
            let keepAlive = retained
            DispatchQueue.main.async { [weak self] in
                guard let self, self.textureGeneration == generation else { return }
                self.desktopTexture = ready.value
                self.params.imageSize = .init(Float(width), Float(height))
                self.params.texAspect = Float(width) / Float(max(1, height))
            }
            withExtendedLifetime(keepAlive) {}
        }
        command.commit()
        return true
    }

    /// The fold shader: a fullscreen triangle plus a fragment that
    /// treats the captured desktop as a rigid plane holding the
    /// activation angle while the lid tilts `delta` radians under it.
    /// At `delta == 0` it early-outs to a plain sample — activating is
    /// pixel-identical, so there is nothing to perceive. The finite eye
    /// is clamped away from the plane (`max(0.25, …)`), so every point
    /// of the gesture is numerically stable.
    private static let shaderSource = """
#include <metal_stdlib>
using namespace metal;

struct FoldParams {
    float2 cover;
    float2 imageSize;
    float delta;
    float aspect;
    float texAspect;
    float blurStrength;
    float dimStrength;
    float persp;
    float samples;
    float motionBoost;
};

struct FoldOut {
    float4 position [[position]];
    float2 uv;
};

constant float FOLD_TAU = 6.28318530718;
constant float FOLD_GOLDEN = 2.39996322973;

vertex FoldOut foldVertex(uint vid [[vertex_id]]) {
    float2 pos = float2(float((vid << 1) & 2), float(vid & 2)) * 2.0 - 1.0;
    FoldOut out;
    out.position = float4(pos, 0.0, 1.0);
    out.uv = float2(pos.x * 0.5 + 0.5, 0.5 - pos.y * 0.5);  // uv.y = 0 top, 1 bottom
    return out;
}

fragment float4 foldFragment(FoldOut in [[stage_in]],
                             texture2d<float> frame [[texture(0)]],
                             constant FoldParams &p [[buffer(0)]],
                             sampler sampl [[sampler(0)]]) {
    float a = clamp(p.delta, 0.0, 1.25);
    if (a < 0.0005) { return frame.sample(sampl, in.uv); }
    float h = 1.0 - in.uv.y;   // 0 at the hinge (bottom), 1 at the far edge

    // The held plane, in screen heights with the hinge at y = 0: the
    // desktop as it stood at activation, counter-rotated by the real
    // lid delta so it stays put in space. persp 0 is the parallel hold
    // (t = 1: pure cos compression, no taper); persp 1 is the full
    // finite-eye keystone from (0, 0.65, 1.6).
    float3 physical = float3((in.uv.x - 0.5) * p.aspect, h * cos(a), h * sin(a));
    float3 eye = float3(0.0, 0.65, 1.6);
    float tPersp = eye.z / max(0.25, eye.z - physical.z);
    float t = mix(1.0, tPersp, p.persp);
    float3 hit = eye + t * (physical - eye);
    float2 uv = float2(hit.x / p.aspect + 0.5, 1.0 - hit.y);
    uv = (uv - 0.5) * p.cover + 0.5;

    // The matte disc: radius grows toward the far edge and with the
    // real tilt — physical defocus, not a gesture curve — plus a
    // velocity term so fast closes smear the way real glass does.
    // Vogel rings (golden-angle spiral, area-uniform) sample real mip
    // levels as they widen, so the blur is continuous instead of a
    // stack of discrete strengths.
    float radPx = (p.blurStrength * 65.0 + p.motionBoost)
                * smoothstep(0.08, 1.0, h) * sin(a);
    float3 color;
    if (radPx < 0.5) {
        color = frame.sample(sampl, uv).rgb;
    } else {
        float uvRadius = radPx / p.imageSize.y;
        float lodCap = min(1.9, radPx * 0.055);
        int taps = int(clamp(p.samples, 8.0, 40.0));
        // A per-pixel phase kills ring banding without animating the disc.
        float phase = fract(sin(dot(in.position.xy, float2(12.9898, 78.233)))
                            * 43758.5453) * FOLD_TAU;
        float3 sum = float3(0.0);
        float weight = 0.0;
        for (int i = 0; i < taps; ++i) {
            float r = sqrt((float(i) + 0.5) / float(taps));
            float ang = phase + float(i) * FOLD_GOLDEN;
            float2 ring = float2(cos(ang) * r / p.texAspect, sin(ang) * r) * uvRadius;
            float w = exp(-r * r * 2.4);
            sum += frame.sample(sampl, uv + ring, level(lodCap * r)).rgb * w;
            weight += w;
        }
        color = sum / weight;
    }

    // A tilted plane catches less light toward its far edge: gentle
    // shading that scales with the real tilt, nothing else painted.
    color *= 1.0 - p.dimStrength * smoothstep(0.0, 1.0, h) * sin(a) * 0.5;

    // Where the projection leaves the captured image there is only
    // void — feathered over the blur's own sigma, never a razor clip.
    float2 feather = max(3.0 * radPx / p.imageSize, fwidth(uv));
    float2 coverage = smoothstep(-feather, feather, uv)
                    * (1.0 - smoothstep(1.0 - feather, 1.0 + feather, uv));
    float mask = coverage.x * coverage.y;
    return float4(mix(float3(0.02, 0.035, 0.05), color, mask), 1.0);
}
"""

    /// The one encode both draw paths share: uniforms from `params`,
    /// aspect/cover fitted to the drawable, one fullscreen triangle.
    private func encodeFold(into encoder: MTLRenderCommandEncoder,
                            source: MTLTexture, aspect: CGFloat) {
        var p = params
        p.aspect = Float(aspect)
        let cx = max(1, p.aspect / p.texAspect)
        let cy = max(1, p.texAspect / p.aspect)
        p.cover = .init(cx, cy)
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(source, index: 0)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.setFragmentBytes(&p, length: MemoryLayout<Params>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    }

    /// Renders the held plane into an offscreen texture — the proof
    /// harness and tests draw without an MTKView. Synchronous: waits
    /// for the GPU before returning, and returns false on any failure.
    @discardableResult
    func render(to target: MTLTexture, size: CGSize) -> Bool {
        guard let source = desktopTexture,
              let command = queue.makeCommandBuffer() else { return false }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        // The shader only paints where the held plane covers; the clear
        // colour is the same void the fragment mixes in at the edge.
        pass.colorAttachments[0].clearColor =
            MTLClearColor(red: 0.02, green: 0.035, blue: 0.05, alpha: 1)
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return false }
        encodeFold(into: encoder, source: source,
                   aspect: size.width / max(1, size.height))
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        return command.status == .completed
    }
}

extension FoldRenderer: MTKViewDelegate {
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard inFlight.wait(timeout: .now()) == .success else { return }
        autoreleasepool {
            guard let source = desktopTexture,
                  let pass = view.currentRenderPassDescriptor,
                  let drawable = view.currentDrawable,
                  let command = queue.makeCommandBuffer(),
                  let encoder = command.makeRenderCommandEncoder(descriptor: pass) else {
                inFlight.signal()
                return
            }
            encodeFold(into: encoder, source: source,
                       aspect: view.drawableSize.width / max(1, view.drawableSize.height))
            encoder.endEncoding()
            command.present(drawable)
            command.addCompletedHandler { [inFlight] _ in
                inFlight.signal()
            }
            command.commit()
        }
    }
}
