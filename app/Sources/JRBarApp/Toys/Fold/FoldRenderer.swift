import AppKit
import CoreVideo
import MetalKit
import MetalPerformanceShaders

/// A frame held alive across the GPU fence: CoreVideo buffers are
/// reference-counted and safe to retain from the completion queue.
private struct RetainedFrame: @unchecked Sendable {
    let buffer: CVPixelBuffer?
    let texture: CVMetalTexture?
}

enum FoldRendererError: LocalizedError {
    case noDevice

    var errorDescription: String? {
        switch self {
        case .noDevice: return "no Metal device"
        }
    }
}

/// One Metal pipeline that projects the captured desktop onto the plane
/// it was captured on — the screen's content holds its angle in the room
/// while the lid swings under it. The shader source is a string, not a
/// `.metal` file: the Command Line Tools toolchain ships no `metal`
/// compiler, so the library is built at runtime and cached in the
/// pipeline. A compile failure throws from `init`, which the toy reports
/// once as "Fold can't start its renderer".
final class FoldRenderer: NSObject {
    /// Per-draw uniforms. `delta` is radians the lid has swung past the
    /// anchor; `persp` blends the parallel projection toward a finite-eye
    /// perspective (keystone taper); `blur` and `dim` scale the Fog and
    /// Dusk terms and arrive pre-multiplied by the fold amount.
    struct Params {
        var delta: Float = 0
        var aspect: Float = 1.6
        var blur: Float = 0
        var persp: Float = 0
        var dim: Float = 0
    }

    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private var textureCache: CVMetalTextureCache?
    /// Four Gaussian levels of the newest frame, baked once per frame —
    /// not per draw — so a draw is one triangle and five texture reads.
    private var blurLevels: [MTLTexture] = []
    private var blurFilters: [MPSImageGaussianBlur] = []
    private var blurDirty = true
    private var desktopTexture: CVMetalTexture?
    private var desktopBuffer: CVPixelBuffer?
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
        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        textureCache = cache
        super.init()
    }

    /// The newest captured frame, pushed once per delivery. Wrapping it
    /// in a Metal texture here — not per draw — is the difference between
    /// one texture conversion per frame and one per redraw.
    @discardableResult
    func setDesktopFrame(_ pixelBuffer: CVPixelBuffer) -> Bool {
        guard let textureCache else { return false }
        var wrapped: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, pixelBuffer, nil, .bgra8Unorm,
            CVPixelBufferGetWidth(pixelBuffer), CVPixelBufferGetHeight(pixelBuffer), 0, &wrapped)
        guard status == kCVReturnSuccess, let wrapped else { return false }
        desktopTexture = wrapped
        desktopBuffer = pixelBuffer
        blurDirty = true
        return true
    }

    private var source: MTLTexture? { desktopTexture.flatMap(CVMetalTextureGetTexture) }

    /// Bakes the blur pyramid for the current frame. The pyramid is
    /// rebuilt only when a new frame lands or the capture size changes;
    /// a draw with a dirty flag and no new frame would just re-blur the
    /// same pixels.
    private func prepareBlur(_ command: MTLCommandBuffer, source: MTLTexture) {
        if blurLevels.first?.width != source.width || blurLevels.first?.height != source.height {
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba16Float, width: source.width, height: source.height, mipmapped: false)
            desc.usage = [.shaderRead, .shaderWrite]
            desc.storageMode = .private
            blurLevels = (0..<4).compactMap { _ in device.makeTexture(descriptor: desc) }
            // Sigmas scale with the frame height so the same radii read
            // the same on any panel; four fixed levels beat a live blur
            // for cost and stay free of sparse-tap speckle.
            blurFilters = [Float(2), 6, 16, 40].map { sigma in
                let filter = MPSImageGaussianBlur(device: device, sigma: sigma * Float(source.height) / 1000)
                filter.edgeMode = .clamp
                return filter
            }
            blurDirty = true
        }
        guard blurDirty, blurLevels.count == 4 else { return }
        for (filter, destination) in zip(blurFilters, blurLevels) {
            filter.encode(commandBuffer: command, sourceTexture: source, destinationTexture: destination)
        }
        blurDirty = false
    }

    /// The fold shader: a fullscreen triangle plus a fragment that treats
    /// the captured desktop as a rigid plane still standing at the angle
    /// it was captured at, and the physical lid as having swung `delta`
    /// radians since. Each pixel is projected back onto the held plane
    /// and sampled there — at delta 0 the projection is the identity, so
    /// activating costs nothing and shows nothing.
    private static let shaderSource = """
#include <metal_stdlib>
using namespace metal;

struct FoldParams {
    float delta;
    float aspect;
    float blur;
    float persp;
    float dim;
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
                             texture2d<float> b1 [[texture(1)]],
                             texture2d<float> b2 [[texture(2)]],
                             texture2d<float> b3 [[texture(3)]],
                             texture2d<float> b4 [[texture(4)]],
                             constant FoldParams &p [[buffer(0)]]) {
    constexpr sampler sampl(filter::linear, address::clamp_to_edge, coord::normalized);
    float h = 1.0 - in.uv.y;   // 0 at the hinge (bottom), 1 at the far edge
    float a = clamp(p.delta, -0.65, 1.25);

    // The held plane: still standing at the anchor, so its pixels sit at
    // height*cos(a) up and height*sin(a) back from the hinge axis.
    float3 held = float3((in.uv.x - 0.5) * p.aspect, h * cos(a), h * sin(a));

    // Parallel projection is the base; `persp` blends in a finite-eye ray
    // (seated viewer, eye slightly above the screen centre) so the far
    // edge tapers the way a real tilted plane does. t = 1 is parallel.
    float3 eye = float3(0.0, 0.65, 1.6);
    float t = 1.0 + p.persp * (eye.z / max(0.25, eye.z - held.z) - 1.0);
    float3 hit = eye + t * (held - eye);
    float2 uv = float2(hit.x / p.aspect + 0.5, 1.0 - hit.y);

    // Defocus grows toward the far edge and with how far the lid has
    // swung — the four Gaussian levels blend by a spatially-varying
    // radius instead of tapping a sparse disc every pixel.
    float radius = p.blur * smoothstep(0.08, 1.0, h) * abs(sin(a)) * 65.0;
    float3 color;
    if (radius < 2.0) {
        color = mix(frame.sample(sampl, uv).rgb, b1.sample(sampl, uv).rgb, radius / 2.0);
    } else if (radius < 6.0) {
        color = mix(b1.sample(sampl, uv).rgb, b2.sample(sampl, uv).rgb, (radius - 2.0) / 4.0);
    } else if (radius < 16.0) {
        color = mix(b2.sample(sampl, uv).rgb, b3.sample(sampl, uv).rgb, (radius - 6.0) / 10.0);
    } else {
        color = mix(b3.sample(sampl, uv).rgb, b4.sample(sampl, uv).rgb,
                    clamp((radius - 16.0) / 24.0, 0.0, 1.0));
    }

    // The folded screen sits in its own shadow toward the top.
    color *= 1.0 - clamp(p.dim * h, 0.0, 0.85);

    // The image boundary feathers out over the same blur radius instead
    // of clipping the already-blurred content to a razor edge; three
    // sigma approximates the Gaussian falloff into the dark surround.
    float2 srcSize = float2(frame.get_width(), frame.get_height());
    float sigmaPx = radius * srcSize.y / 1000.0;
    float2 feather = max(3.0 * sigmaPx / srcSize, fwidth(uv));
    float2 coverage = smoothstep(-feather, feather, uv)
                    * (1.0 - smoothstep(1.0 - feather, 1.0 + feather, uv));
    float mask = coverage.x * coverage.y;
    return float4(mix(float3(0.02, 0.035, 0.05), color, mask), 1.0);
}
"""
}

extension FoldRenderer: MTKViewDelegate {
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard inFlight.wait(timeout: .now()) == .success else { return }
        autoreleasepool {
            guard let source,
                  let pass = view.currentRenderPassDescriptor,
                  let drawable = view.currentDrawable,
                  let command = queue.makeCommandBuffer() else {
                inFlight.signal()
                return
            }
            // The pyramid only rebakes when a new frame made it dirty and
            // the style actually blurs; aligned draws never pay for it.
            // It must encode before the render encoder opens — a command
            // buffer holds one live encoder at a time.
            if params.blur > 1e-4 && abs(params.delta) > 0.003 { prepareBlur(command, source: source) }
            guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else {
                inFlight.signal()
                return
            }
            let retained = RetainedFrame(buffer: desktopBuffer, texture: desktopTexture)
            var p = params
            p.aspect = Float(view.drawableSize.width / max(1, view.drawableSize.height))
            encoder.setRenderPipelineState(pipeline)
            encoder.setFragmentTexture(source, index: 0)
            for index in 0..<4 {
                encoder.setFragmentTexture(blurLevels.indices.contains(index) ? blurLevels[index] : source,
                                           index: index + 1)
            }
            encoder.setFragmentBytes(&p, length: MemoryLayout<Params>.stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
            command.present(drawable)
            // The capture surfaces must stay alive until the GPU is done
            // reading them — the completion handler owns the release.
            command.addCompletedHandler { [inFlight] _ in
                withExtendedLifetime(retained) {}
                inFlight.signal()
            }
            command.commit()
        }
    }
}
