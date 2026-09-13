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

/// One Metal pipeline that draws the fold as the iPhone-Duo gesture it
/// is modeled on: the captured desktop is a rigid plane still standing
/// at its captured angle while the physical lid swings under it, on a
/// bounded 0…1 `turn` arc that ends in a designed fade to void rather
/// than an ever-steeper tilt.
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
    /// Per-draw uniforms. `turn` is the normalized fold gesture (0 at
    /// the activation angle, 1 fully closed). `blurStrength`/`dimStrength`
    /// carry the style, `persp` blends orthographic hold into finite-eye
    /// keystone, `samples` adapts the blur disc to the gesture, and
    /// `motionBoost` (in blur-radius units) is the velocity term that
    /// keeps fast slams silky instead of stepping.
    struct Params {
        var cover: SIMD2<Float> = .init(1, 1)
        var imageSize: SIMD2<Float> = .init(1, 1)
        var turn: Float = 0
        var aspect: Float = 1.6
        var texAspect: Float = 1.6
        var blurStrength: Float = 0
        var dimStrength: Float = 0
        var reflection: Float = 1
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
    /// treats the captured desktop as a rigid plane holding its angle.
    /// At `turn == 0` it early-outs to a plain sample — activating is
    /// pixel-identical, so there is nothing to perceive. The projection
    /// is bounded by construction (the denominator can never reach the
    /// eye), so every point of the gesture is numerically stable.
    private static let shaderSource = """
#include <metal_stdlib>
using namespace metal;

struct FoldParams {
    float2 cover;
    float2 imageSize;
    float turn;
    float aspect;
    float texAspect;
    float blurStrength;
    float dimStrength;
    float reflection;
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
    float turn = clamp(p.turn, 0.0, 1.0);
    if (turn < 0.0005) { return frame.sample(sampl, in.uv); }
    float h = 1.0 - in.uv.y;   // 0 at the hinge (bottom), 1 at the far edge

    // The held plane: bend grows with the gesture but is capped near
    // 48° — the Duo arc stays composed instead of keeling over.
    float bend = pow(turn, 1.18) * 0.84;
    float invAspect = 1.0 / p.aspect;
    float eye = 3.2 * invAspect;
    float depth = h * 0.8 * invAspect * sin(bend);
    float proj = eye / max(eye - depth, 1e-3);
    // persp 0 is the orthographic hold (cos compression, no taper);
    // persp 1 is the full finite-eye keystone.
    float taper = mix(1.0, proj, p.persp);
    float vmap = mix(cos(bend), 1.0 / proj, p.persp);
    float2 uv = float2(0.5 + (in.uv.x - 0.5) / taper, 1.0 - h * vmap);
    uv = (uv - 0.5) * p.cover + 0.5;

    // The matte disc: radius grows toward the far edge and with the
    // gesture, plus a velocity term so fast closes smear the way real
    // glass does. Vogel rings — golden-angle spiral, area-uniform —
    // sample real mip levels as they widen, so the blur is continuous
    // instead of a stack of discrete strengths.
    float matte = smoothstep(0.06, 1.0, h) * smoothstep(0.0, 0.30, turn);
    float radPx = (p.blurStrength * 34.0 + p.motionBoost) * pow(turn, 0.72) * matte;
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

    // Glass: a tilted glossy panel dims as it turns, catches a sheen
    // band above the hinge, and seams bright right at the fold line.
    color *= 1.0 - pow(turn, 1.2) * pow(h, 1.5) * 0.22;
    float sheen = exp(-pow((h - 0.62) * 2.6, 2.0)) * pow(turn, 1.4) * 0.09 * p.reflection;
    color += sheen;
    float seam = (1.0 - smoothstep(0.0, 0.045, h)) * smoothstep(0.02, 0.2, turn);
    color += seam * 0.07 * p.reflection;

    // The void beyond the held plane, then the gesture's final close —
    // the last tenth of the arc finishes to near-black, so a full close
    // reads as the display switching off, not the image vanishing.
    float3 voidColor = float3(0.018, 0.028, 0.045);
    float voidStart = 0.55 - 0.08 * turn;
    float voidFade = smoothstep(voidStart, 1.0, h) * pow(turn, 1.1) * p.dimStrength;
    color = mix(color, voidColor, clamp(voidFade, 0.0, 1.0));
    float closeFade = smoothstep(0.88, 1.0, turn);
    color = mix(color, float3(0.004, 0.005, 0.008), closeFade);

    // Where the projection leaves the captured image there is only
    // void — feathered over a few pixels, never a razor clip.
    float edge = smoothstep(-0.006, 0.006, uv.x)
               * (1.0 - smoothstep(1.0 - 0.006, 1.0 + 0.006, uv.x))
               * smoothstep(-0.009, 0.009, uv.y)
               * (1.0 - smoothstep(1.0 - 0.009, 1.0 + 0.009, uv.y));
    return float4(mix(voidColor, color, edge), 1.0);
}
"""
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
            var p = params
            p.aspect = Float(view.drawableSize.width / max(1, view.drawableSize.height))
            let cx = max(1, p.aspect / p.texAspect)
            let cy = max(1, p.texAspect / p.aspect)
            p.cover = .init(cx, cy)
            encoder.setRenderPipelineState(pipeline)
            encoder.setFragmentTexture(source, index: 0)
            encoder.setFragmentSamplerState(sampler, index: 0)
            encoder.setFragmentBytes(&p, length: MemoryLayout<Params>.stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
            command.present(drawable)
            command.addCompletedHandler { [inFlight] _ in
                inFlight.signal()
            }
            command.commit()
        }
    }
}
