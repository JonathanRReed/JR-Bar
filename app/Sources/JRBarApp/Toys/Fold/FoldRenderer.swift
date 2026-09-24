import AppKit
import CoreVideo
import JRBarCore
import MetalKit
import MetalPerformanceShaders
import OSLog

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

/// A hot-path log that cannot flood: each distinct message repeats at
/// most once a second. Frames arrive at 60 Hz — a real failure would
/// otherwise bury the log that is supposed to explain it.
private nonisolated(unsafe) var foldThrottle: [String: TimeInterval] = [:]
private func foldLogThrottled(_ message: String) {
    let now = ProcessInfo.processInfo.systemUptime
    if now - (foldThrottle[message] ?? 0) < 1 { return }
    foldThrottle[message] = now
    FoldLog.log.warning("\(message, privacy: .public)")
}

/// The fold's Metal renderer, with one pipeline per look.
///
/// **Duo** (`duoFragment`): the iPhone Duo's fold. One captured frame
/// lands in a persistent 8-level Gaussian pyramid (MPS, with plain
/// mipmaps as the fallback); each glass pixel samples the picture point
/// a seated eye saw behind it on the resting lid (`FoldDuoModel`), reads
/// the level that carries its blur as a smooth B-spline — no disc, so
/// no ghost copies — darkens away from the hinge, and fades to black as
/// the eye loses the glass. The void is pure black; no sheen, no seam.
/// `blackout` draws the closed-lid hold as the clear alone: no pipeline
/// and no texture.
///
/// **Room** (`foldFragment`): the fold as a room seen through a portal:
/// the screen is a window into a space behind it, hanging off the
/// hinge, so closing the lid reads as the UI continuing INTO the
/// display rather than a flat image tilting.
///
/// The room is a stack of planes parallel to the screen: the wallpaper
/// is the far wall at `roomDepth`, and each on-screen window is a card
/// floating at its own depth, punched into one alpha texture per depth
/// bucket (`PortalDepth`). Every layer rides the hinge's rotation, so at
/// `delta == 0` every mapping is the identity — activating is invisible.
/// As delta grows, deeper layers compress and shift more than near ones
/// (true parallax), mip-LOD defocus grows with depth-from-focus and
/// closure, and the Frost knob turns the room into a frosted-
/// polypropylene cover: the void lifts to a cool grey-milk, the capture
/// desaturates and its black point rises as if seen through diffused
/// plastic, a specular sheen tracks the bend and a thin rim keeps the
/// silhouette readable. Distance fog and a hinge vignette still deepen
/// it, and the whole composite dissolves to black over the last ~20°
/// of travel — a shut cover is opaque.
///
/// Frames arrive as IOSurface-backed buffers and land in persistent
/// private mipmapped textures via GPU blits — no per-frame texture
/// allocation in the render loop. The shader source is a string, not a
/// `.metal` file: the Command Line Tools toolchain ships no `metal`
/// compiler, so the library is built at runtime and cached in the
/// pipeline. A compile failure throws from `init`, which the toy
/// reports once as "Fold can't start its renderer".
final class FoldRenderer: NSObject, @unchecked Sendable {
    /// Per-draw uniforms. `delta` is the lid's travel past the reference
    /// angle in radians (0 at activation, clamped at 1.25). `depths` is
    /// each bucket's depth in screen heights (0 is the glass,
    /// `roomDepth` the far wall); `mode` 1 is the Reduce-Motion flat
    /// dimmed desktop. The Swift layout must match `FoldParams` in the
    /// shader source field-for-field.
    struct Params {
        var depths: SIMD4<Float> = .zero
        var cover: SIMD2<Float> = .init(1, 1)
        var imageSize: SIMD2<Float> = .init(1, 1)
        var eye: SIMD2<Float> = .init(0.65, 1.6)
        var delta: Float = 0
        var aspect: Float = 1.6
        var texAspect: Float = 1.6
        var persp: Float = 0.6
        var blurStrength: Float = 0.5
        var dimStrength: Float = 0.4
        var opacity: Float = 1
        var dissolve: Float = 0
        var glowStrength: Float = 0.7
        var fogStrength: Float = 0.8
        var roomDepth: Float = 0.45
        var mode: Float = 0
        var bucketCount: Float = 0
        var frost: Float = 0.65
        /// The viewer-compensation fraction: 0 the picture rides the
        /// lid, 1 the content plane takes the full front-view mapping so
        /// a fixed eye sees it hold its place.
        var hold: Float = 1
        // Duo fields, appended so the Room's offsets never move. Angles
        // in radians, lengths in screen heights.
        /// The resting lid — the plane whose picture stays put.
        var thetaRef: Float = 0
        /// The lid now.
        var theta: Float = 0
        /// The seated eye: toward the person, and up from the deck.
        var eyeF: Float = 2.6
        var eyeU: Float = 2.0
        /// The eased 0…1 transition that drives blur and darkening.
        var motion: Float = 0
        /// Far-edge blur σ at full motion.
        var blurMax: Float = 0
        /// Darkening gain (2 is the Duo's own).
        var darkGain: Float = 0
        /// 0…1 to black as the eye loses the glass.
        var endFade: Float = 0
        /// 1 draws flat black with nothing sampled — the closed-lid hold.
        var blackout: Float = 0
        /// Levels in the Duo's pyramid; set by the upload.
        var lodCount: Float = 1
        /// 1 when MPS built the pyramid: its levels sit (2^L − 1)/2 base
        /// pixels right and down of where they belong, and the read
        /// shifts them back. 0 for plain mipmaps, which stay centred.
        var pyramidShift: Float = 0
    }

    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let duoPipeline: MTLRenderPipelineState
    private let sampler: MTLSamplerState
    /// Which look the uploads feed and the encode draws. A change drops
    /// `hasTexture` until a frame lands in the new look's texture.
    var look: FoldLook = .room {
        didSet {
            guard look != oldValue else { return }
            hasTexture = false
            textureGeneration &+= 1
        }
    }
    /// The Duo's picture: the newest frame as an 8-level Gaussian
    /// pyramid, persistent and reused every frame.
    private(set) var duoPyramid: MTLTexture?
    /// MPS's pyramid kernel, or nil where MPS can't run on this device —
    /// then the pyramid is plain mipmaps.
    private let gaussianPyramid: MPSImageGaussianPyramid?
    private var textureCache: CVMetalTextureCache?
    /// The newest full capture as a private mipmapped texture. Published
    /// on the main actor after the blit commits, generation-guarded so
    /// an older overlapping upload can never overwrite a newer one.
    private var fullTexture: MTLTexture?
    /// The far wall — the wallpaper-only stream. `nil` until its first
    /// frame lands; the encode binds `fullTexture` there until it does.
    private var farTexture: MTLTexture?
    /// One alpha-punched texture per depth bucket, persistent and reused
    /// every frame — the render loop allocates nothing.
    private var bucketTextures: [MTLTexture] = []
    /// Bound in place of any bucket that isn't live this frame.
    private var dummyTexture: MTLTexture?
    /// The current card layout; restamped into the buckets on every
    /// full frame. `layoutDirty` forces a bucket clear first.
    private var cards: [PortalDepth.Card] = []
    private var layoutDirty = false
    /// True once a captured frame has landed as a drawable texture —
    /// `hasFrame` upstream says a frame arrived; this says the GPU can
    /// sample it.
    private(set) var hasTexture = false
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
        let duoDescriptor = MTLRenderPipelineDescriptor()
        duoDescriptor.vertexFunction = library.makeFunction(name: "foldVertex")
        duoDescriptor.fragmentFunction = library.makeFunction(name: "duoFragment")
        duoDescriptor.colorAttachments[0].pixelFormat = pixelFormat
        duoPipeline = try device.makeRenderPipelineState(descriptor: duoDescriptor)
        gaussianPyramid = MPSSupportsMTLDevice(device) ? MPSImageGaussianPyramid(device: device) : nil
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
        // A 1x1 transparent placeholder for unbound bucket slots.
        let dummyDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: 1, height: 1, mipmapped: false)
        dummyDesc.usage = .shaderRead
        dummyDesc.storageMode = .shared
        let dummy = device.makeTexture(descriptor: dummyDesc)
        dummy?.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0,
                       withBytes: [UInt8](repeating: 0, count: 4), bytesPerRow: 4)
        dummyTexture = dummy
        super.init()
    }

    /// The window-card layout, from `FoldCapture`'s CGWindowList poll.
    /// Stays applied across frames; the next full frame restamps it.
    func setCards(_ cards: [PortalDepth.Card]) {
        guard cards != self.cards else { return }
        self.cards = cards
        layoutDirty = true
    }

    /// How many depth buckets currently hold a card — the param
    /// mapper's `usedBuckets`.
    var usedBucketCount: Int {
        (cards.map(\.bucket).max() ?? -1) + 1
    }

    private func roomTexture(width: Int, height: Int) -> MTLTexture? {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: true)
        desc.mipmapLevelCount = 6
        // RenderTarget is not optional here: a layout change clears the
        // bucket textures through a real render pass, and a usage of
        // shaderRead-only fails Metal validation — silently dropped in
        // release, which left stale card pixels behind.
        desc.usage = [.shaderRead, .renderTarget]
        desc.storageMode = .private
        return device.makeTexture(descriptor: desc)
    }

    /// Ensures the persistent room textures match the capture's size.
    /// Recreated only when the size changes — the steady-state render
    /// loop allocates nothing.
    private func ensureRoomTextures(width: Int, height: Int) -> Bool {
        if fullTexture?.width == width, fullTexture?.height == height,
           bucketTextures.count == PortalDepth.bucketCount {
            return true
        }
        guard let full = roomTexture(width: width, height: height) else { return false }
        var buckets: [MTLTexture] = []
        for _ in 0..<PortalDepth.bucketCount {
            guard let b = roomTexture(width: width, height: height) else { return false }
            buckets.append(b)
        }
        fullTexture = full
        bucketTextures = buckets
        layoutDirty = true
        params.imageSize = .init(Float(width), Float(height))
        params.texAspect = Float(width) / Float(max(1, height))
        return true
    }

    /// The newest full-capture frame, pushed once per delivery. The
    /// IOSurface texture blits into the persistent private copy on the
    /// GPU, the window cards are restamped into their depth buckets,
    /// and the touched textures get fresh mipmaps — all in one command
    /// buffer, no CPU decode, no staging.
    @discardableResult
    func setFullFrame(_ pixelBuffer: CVPixelBuffer) -> Bool {
        guard let textureCache else {
            foldLogThrottled("setFullFrame: no texture cache")
            return false
        }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        var wrapped: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, pixelBuffer, nil, .bgra8Unorm,
            width, height, 0, &wrapped)
        guard status == kCVReturnSuccess, let wrapped,
              let source = CVMetalTextureGetTexture(wrapped) else {
            foldLogThrottled("setFullFrame: cache wrap failed status=\(status)")
            return false
        }
        if look == .duo {
            return setDuoFrame(source, retained: RetainedFrame(buffer: pixelBuffer, texture: wrapped))
        }
        guard ensureRoomTextures(width: width, height: height),
              let full = fullTexture,
              let command = queue.makeCommandBuffer() else {
            foldLogThrottled("setFullFrame: texture/command alloc failed")
            return false
        }
        // A layout change means stale card pixels in the buckets — clear
        // them before restamping. A no-draw pass per bucket is the cheap
        // way to zero the alpha.
        if layoutDirty {
            for bucket in bucketTextures {
                let pass = MTLRenderPassDescriptor()
                pass.colorAttachments[0].texture = bucket
                pass.colorAttachments[0].loadAction = .clear
                pass.colorAttachments[0].storeAction = .store
                pass.colorAttachments[0].clearColor =
                    MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
                let enc = command.makeRenderCommandEncoder(descriptor: pass)
                enc?.endEncoding()
            }
            layoutDirty = false
        }
        guard let blit = command.makeBlitCommandEncoder() else {
            foldLogThrottled("setFullFrame: blit alloc failed")
            return false
        }
        blit.copy(from: source, sourceSlice: 0, sourceLevel: 0,
                  sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: width, height: height, depth: 1),
                  to: full, destinationSlice: 0, destinationLevel: 0,
                  destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.generateMipmaps(for: full)
        // Restamp each card's rect from the fresh frame into its depth
        // bucket. Back-to-front within a bucket so the front card's
        // pixels win where rects overlap.
        var touchedBuckets = Set<Int>()
        for card in cards.reversed() {
            let x = Int(card.rect.minX * Double(width))
            let y = Int(card.rect.minY * Double(height))
            let w = min(width - x, Int((card.rect.width * Double(width)).rounded(.up)))
            let h = min(height - y, Int((card.rect.height * Double(height)).rounded(.up)))
            guard x >= 0, y >= 0, w > 0, h > 0,
                  card.bucket >= 0, card.bucket < bucketTextures.count else { continue }
            blit.copy(from: source, sourceSlice: 0, sourceLevel: 0,
                      sourceOrigin: MTLOrigin(x: x, y: y, z: 0),
                      sourceSize: MTLSize(width: w, height: h, depth: 1),
                      to: bucketTextures[card.bucket],
                      destinationSlice: 0, destinationLevel: 0,
                      destinationOrigin: MTLOrigin(x: x, y: y, z: 0))
            touchedBuckets.insert(card.bucket)
        }
        for bucket in touchedBuckets {
            blit.generateMipmaps(for: bucketTextures[bucket])
        }
        blit.endEncoding()
        publishOnCompletion(command, retained: RetainedFrame(buffer: pixelBuffer, texture: wrapped),
                            texture: full)
        command.commit()
        return true
    }

    /// Marks the texture drawable once `command` finishes, unless a newer
    /// upload (or a look change) has overtaken it.
    private func publishOnCompletion(_ command: MTLCommandBuffer, retained: RetainedFrame,
                                     texture: MTLTexture) {
        textureGeneration &+= 1
        let generation = textureGeneration
        let ready = SendBox(texture)
        let width = texture.width, height = texture.height
        command.addCompletedHandler { [weak self] _ in
            let keepAlive = retained
            DispatchQueue.main.async { [weak self] in
                guard let self, self.textureGeneration == generation else { return }
                if !self.hasTexture {
                    FoldLog.log.notice("renderer: first texture published \(width)x\(height)")
                }
                self.hasTexture = true
                _ = ready
            }
            withExtendedLifetime(keepAlive) {}
        }
    }

    /// The Duo's persistent pyramid, recreated only when the capture's
    /// size changes. Usage includes shaderWrite: MPS writes the levels.
    private func ensureDuoPyramid(width: Int, height: Int) -> MTLTexture? {
        if let pyramid = duoPyramid, pyramid.width == width, pyramid.height == height {
            return pyramid
        }
        let fit = Int(log2(Double(max(1, max(width, height))))) + 1
        let levels = max(1, min(FoldDuoModel.pyramidLevels, fit))
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: levels > 1)
        desc.mipmapLevelCount = levels
        desc.usage = [.shaderRead, .shaderWrite]
        desc.storageMode = .private
        guard let pyramid = device.makeTexture(descriptor: desc) else { return nil }
        duoPyramid = pyramid
        params.imageSize = .init(Float(width), Float(height))
        params.texAspect = Float(width) / Float(max(1, height))
        params.lodCount = Float(levels)
        return pyramid
    }

    /// The Duo upload: one blit into the pyramid's base, then MPS's
    /// Gaussian pyramid fills the levels in place — or plain mipmaps
    /// where MPS can't. No cards, no far wall, one texture.
    private func setDuoFrame(_ source: MTLTexture, retained: RetainedFrame) -> Bool {
        let width = source.width, height = source.height
        guard let pyramid = ensureDuoPyramid(width: width, height: height),
              let command = queue.makeCommandBuffer(),
              let blit = command.makeBlitCommandEncoder() else {
            foldLogThrottled("setDuoFrame: texture/command alloc failed")
            return false
        }
        blit.copy(from: source, sourceSlice: 0, sourceLevel: 0,
                  sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: width, height: height, depth: 1),
                  to: pyramid, destinationSlice: 0, destinationLevel: 0,
                  destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        let useMPS = gaussianPyramid != nil && pyramid.mipmapLevelCount > 1
        if !useMPS && pyramid.mipmapLevelCount > 1 { blit.generateMipmaps(for: pyramid) }
        blit.endEncoding()
        if useMPS, let kernel = gaussianPyramid {
            var target: MTLTexture = pyramid
            let encoded = withUnsafeMutablePointer(to: &target) {
                kernel.encode(commandBuffer: command, inPlaceTexture: $0, fallbackCopyAllocator: nil)
            }
            if !encoded, let mips = command.makeBlitCommandEncoder() {
                foldLogThrottled("setDuoFrame: MPS pyramid refused, using mipmaps")
                mips.generateMipmaps(for: pyramid)
                mips.endEncoding()
                params.pyramidShift = 0
                publishOnCompletion(command, retained: retained, texture: pyramid)
                command.commit()
                return true
            }
        }
        params.pyramidShift = useMPS ? 1 : 0
        publishOnCompletion(command, retained: retained, texture: pyramid)
        command.commit()
        return true
    }

    /// The newest far-wall frame. Same blit path as the full frame,
    /// minus the card stamping.
    @discardableResult
    func setFarFrame(_ pixelBuffer: CVPixelBuffer) -> Bool {
        guard let textureCache else { return false }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        var wrapped: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, pixelBuffer, nil, .bgra8Unorm,
            width, height, 0, &wrapped) == kCVReturnSuccess,
              let wrapped, let source = CVMetalTextureGetTexture(wrapped)
        else { return false }
        if farTexture?.width != width || farTexture?.height != height {
            guard let tex = roomTexture(width: width, height: height) else { return false }
            farTexture = tex
        }
        guard let far = farTexture, let command = queue.makeCommandBuffer(),
              let blit = command.makeBlitCommandEncoder() else { return false }
        blit.copy(from: source, sourceSlice: 0, sourceLevel: 0,
                  sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: width, height: height, depth: 1),
                  to: far, destinationSlice: 0, destinationLevel: 0,
                  destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.generateMipmaps(for: far)
        blit.endEncoding()
        let retained = RetainedFrame(buffer: pixelBuffer, texture: wrapped)
        command.addCompletedHandler { _ in withExtendedLifetime(retained) {} }
        command.commit()
        return true
    }

    /// The portal shader: a fullscreen triangle plus a fragment that
    /// ray-projects through the room's depth layers. The room rides the
    /// lid's rotation about the hinge; the finite eye is normalized so
    /// every depth maps to itself at delta = 0 — activating is
    /// pixel-identical, there is nothing to perceive.
    static let shaderSource = """
#include <metal_stdlib>
using namespace metal;

struct FoldParams {
    float4 depths;      // bucket depths in screen heights, nearest first
    float2 cover;       // cover-fit scale for texture sampling
    float2 imageSize;   // capture pixels
    float2 eye;         // (y, z) in screen heights
    float delta;        // lid travel past activation, radians
    float aspect;       // drawable aspect
    float texAspect;
    float persp;        // 0 parallel hold .. 1 finite eye
    float blurStrength;
    float dimStrength;
    float opacity;      // activation-edge ramp (the window alpha owns it)
    float dissolve;     // 0..1 fade to black over the last ~20 degrees
    float glowStrength; // hinge-seam light
    float fogStrength;  // distance fog
    float roomDepth;    // far-wall depth in screen heights
    float mode;         // 0 portal, 1 Reduce-Motion flat dim
    float bucketCount;
    float frost;        // 0 bare dark room .. 1 frosted-PP cover
    float hold;         // 0 picture rides the lid .. 1 holds its place
    // Duo, appended in the Swift order. Radians and screen heights.
    float thetaRef;     // the resting lid: the plane whose picture stays
    float theta;        // the lid now
    float eyeF;         // the seated eye, toward the person
    float eyeU;         // and up from the deck
    float motion;       // eased 0..1 transition for blur and darkening
    float blurMax;      // far-edge sigma at motion 1, fraction of H
    float darkGain;     // darkening gain (2 = the Duo's 2x)
    float endFade;      // 0..1 to black as the eye loses the glass
    float blackout;     // 1 = flat black
    float lodCount;     // pyramid levels
    float pyramidShift; // 1 = undo MPS's decimation offset
};

struct FoldOut {
    float4 position [[position]];
    float2 uv;
};

constant float FOLD_TAU = 6.28318530718;
constant float FOLD_GOLDEN = 2.39996322973;
constant int FOLD_TAPS = 10;

vertex FoldOut foldVertex(uint vid [[vertex_id]]) {
    float2 pos = float2(float((vid << 1) & 2), float(vid & 2)) * 2.0 - 1.0;
    FoldOut out;
    out.position = float4(pos, 0.0, 1.0);
    out.uv = float2(pos.x * 0.5 + 0.5, 0.5 - pos.y * 0.5);  // uv.y = 0 top, 1 bottom
    return out;
}

// Where a screen-space uv lands on the layer at depth d: the layer is
// the screen plane pushed d screen-heights into the room and rotated
// with the lid about the hinge. The perspective term is normalized by
// its own delta=0 value so every depth is the identity at activation —
// the portal materializes out of the untouched desktop.
static float2 foldLayerUV(float2 uv, float a, float d, constant FoldParams &p) {
    float h = 1.0 - uv.y;   // 0 at the hinge (bottom), 1 at the far edge
    float3 P = float3((uv.x - 0.5) * p.aspect,
                      h * cos(a) + d * sin(a),
                      h * sin(a) - d * cos(a));
    float3 eye = float3(0.0, p.eye.x, p.eye.y);
    float t = mix(1.0, (eye.z + d) / max(0.25, eye.z - P.z), p.persp);
    float3 hit = eye + t * (P - eye);
    return float2(hit.x / p.aspect + 0.5, 1.0 - hit.y);
}

// The defocus matte, one surface at a time. `lod` is the surface's
// depth-of-field blur floor, `radUV` the disc radius in texture space.
// Vogel rings (golden-angle spiral, area-uniform) sample real mip
// levels — taps near the rim read deeper mips — so the disc stays
// velvet at any radius instead of speckling like a sparse-tap fake.
// Alpha rides along so the window cards blur their own edges.
static float4 foldBlur(texture2d<float> tex, sampler s, float2 uv,
                       float radUV, float lod, float texAspect, float phase) {
    if (radUV < 0.0001) {
        return tex.sample(s, uv, level(lod));
    }
    float4 sum = float4(0.0);
    float weight = 0.0;
    for (int i = 0; i < FOLD_TAPS; ++i) {
        float r = sqrt((float(i) + 0.5) / float(FOLD_TAPS));
        float ang = phase + float(i) * FOLD_GOLDEN;
        float2 ring = float2(cos(ang) * r / texAspect, sin(ang) * r) * radUV;
        float w = exp(-r * r * 2.4);
        sum += tex.sample(s, uv + ring, level(min(5.0, lod * (0.5 + r)))) * w;
        weight += w;
    }
    return sum / weight;
}

fragment float4 foldFragment(FoldOut in [[stage_in]],
                             texture2d<float> full [[texture(0)]],
                             texture2d<float> bucket0 [[texture(1)]],
                             texture2d<float> bucket1 [[texture(2)]],
                             texture2d<float> bucket2 [[texture(3)]],
                             texture2d<float> far [[texture(4)]],
                             constant FoldParams &p [[buffer(0)]],
                             sampler sampl [[sampler(0)]]) {
    if (p.mode > 0.5) {
        // Reduce Motion: no room and no tilt — the desktop itself,
        // dimmed and diffused through the same frosted sheet, behind a
        // crossfade the window's alpha owns.
        float2 fuv = (in.uv - 0.5) * p.cover + 0.5;
        float3 c = full.sample(sampl, fuv).rgb;
        float rmFrost = clamp(p.frost, 0.0, 1.0);
        float3 rmMilk = float3(0.72, 0.75, 0.79);
        float rmLum = dot(c, float3(0.2126, 0.7152, 0.0722));
        c = mix(c, float3(rmLum), 0.34 * rmFrost);
        c = mix(c, rmMilk, 0.28 * rmFrost);
        c *= 1.0 - 0.45 * p.dimStrength;
        c = mix(c, float3(0.0), p.dissolve);
        return float4(c, 1.0);
    }

    float a = clamp(p.delta, 0.0, 1.25);
    // Hold-in-place: `foldLayerUV` at the full delta IS the front-view
    // mapping (a fixed eye sees the picture stay put), and at 0 it is
    // the identity (the picture glued to the glass). So the content
    // plane takes delta·hold: 1 holds, 0 rides the lid, and the room's
    // own terms (fog, shade, dissolve, sheen) still read the real delta.
    float aL = a * clamp(p.hold, 0.0, 1.0);
    float h = 1.0 - in.uv.y;
    float sa = sin(a);
    // The sheet itself: frosted polypropylene. `milk` is the plastic's
    // own colour — light, faintly cool, never paper-white. `roomVoid`
    // replaces the bare room's dark: past the far wall there is only
    // diffused light, so the void is the milk a shade deeper. At
    // frost == 0 both collapse to the old dark room exactly.
    float frost = clamp(p.frost, 0.0, 1.0);
    float3 milk = float3(0.72, 0.75, 0.79);
    float3 roomVoid = mix(float3(0.012, 0.02, 0.032), milk * 0.88, frost);
    // Progressive defocus, mastered by the Blur knob: the mip LOD grows
    // with closure, with depth from the focal surface, and toward the
    // far edge — deeper layers soften first and the hinge stays sharp
    // longest. The disc radius in texture space grows toward the far
    // edge like the old matte did.
    float lodStep = p.blurStrength * 4.0 * sa;
    float lodEdge = 0.5 + 0.5 * h;
    float radUV = p.blurStrength * 0.045 * smoothstep(0.08, 1.0, h) * sa;
    // A per-pixel phase kills ring banding without animating the disc.
    float phase = fract(sin(dot(in.position.xy, float2(12.9898, 78.233)))
                        * 43758.5453) * FOLD_TAU;

    float3 color = float3(0.0);
    float winDepth = p.roomDepth;
    bool covered = false;

    // Cards, nearest bucket first — the first opaque hit wins.
    for (int i = 0; i < 3; ++i) {
        if (covered || float(i) >= p.bucketCount) { continue; }
        float d = p.depths[i];
        float depthN_i = d / max(0.05, p.roomDepth);
        float2 luv = (foldLayerUV(in.uv, aL, d, p) - 0.5) * p.cover + 0.5;
        float lod = min(5.0, lodStep * (0.25 + depthN_i) * lodEdge);
        float rad = radUV * (0.35 + 0.65 * depthN_i);
        texture2d<float> bucket = i == 0 ? bucket0 : (i == 1 ? bucket1 : bucket2);
        float4 c = foldBlur(bucket, sampl, luv, rad, lod, p.texAspect, phase);
        c.a *= step(0.0, luv.x) * step(0.0, luv.y)
             * step(luv.x, 1.0) * step(luv.y, 1.0);
        if (c.a > 0.04) {
            color = c.rgb;
            winDepth = d;
            covered = true;
        }
    }

    if (!covered) {
        // The far wall — the deepest layer, so it takes the strongest
        // defocus. Out past the room there is only void — feathered
        // over the defocus's own scale, never a razor clip.
        float d = p.roomDepth;
        float2 luv = (foldLayerUV(in.uv, aL, d, p) - 0.5) * p.cover + 0.5;
        float lod = min(5.0, lodStep * 1.2 * lodEdge);
        float3 c = foldBlur(far, sampl, luv, radUV * 1.1, lod, p.texAspect, phase).rgb;
        float2 feather = max(float2(2.0) / p.imageSize + radUV, fwidth(luv));
        float2 cov = smoothstep(-feather, feather, luv)
                   * (1.0 - smoothstep(1.0 - feather, 1.0 + feather, luv));
        color = mix(roomVoid, c, cov.x * cov.y);
    }

    // Diffusion through the sheet: the capture desaturates and its
    // black point lifts toward the milk — the content stays readable
    // but reads as seen THROUGH frosted plastic, not pasted under it.
    float lum = dot(color, float3(0.2126, 0.7152, 0.0722));
    color = mix(color, float3(lum), 0.34 * frost);
    color = mix(color, milk, 0.28 * frost);

    // Distance fog: the deeper the surface the more it sinks toward the
    // room's floor as the lid closes, and the far end fogs first — at
    // frost that floor is the milk, so depth reads as thicker plastic.
    float depthN = clamp(winDepth / max(0.05, p.roomDepth), 0.0, 1.0);
    color = mix(color, roomVoid,
                p.fogStrength * depthN * sa * (0.45 + 0.55 * h));
    // The hinge vignette: the room darkens toward the seam, and the far
    // wall sits permanently deeper in the shade.
    color *= 1.0 - p.dimStrength * (0.4 * smoothstep(0.5, 0.0, h) * sa
                                    + 0.3 * depthN);
    // The bend sheen — light catching the curved plastic. `seam` is the
    // old lit hinge line, retinted from blue to near-neutral as the
    // frost comes up; `bendBand` is a soft specular lobe peaking just
    // inside the bend, `edgeCurl` the secondary sheen where the sheet
    // curls away at the far edge, and `rim` a thin fresnel-ish line
    // that keeps the silhouette readable. A sheen, not a laser.
    float3 sheenTint = mix(float3(0.32, 0.46, 0.62), float3(0.95, 0.97, 1.0), frost);
    float seam = exp(-h * 18.0);
    float bendBand = exp(-pow((h - 0.08) * 7.0, 2.0));
    float edgeCurl = exp(-(1.0 - h) * 9.0);
    float rim = exp(-(1.0 - h) * 48.0);
    color += sheenTint * sa * p.glowStrength
           * (seam * 0.55 + (bendBand * 0.30 + edgeCurl * 0.20) * frost);
    color += float3(0.92, 0.95, 1.0) * rim * sa * frost * 0.30;
    // The dissolve: everything goes to black over the last ~20 degrees
    // — a shut cover is opaque, the frost is the open-ish state.
    color = mix(color, float3(0.0), p.dissolve);
    return float4(color, 1.0);
}

// ---- Duo -------------------------------------------------------------
// Side view of the lid in screen heights, hinge at the origin: forward
// toward the person, up from the deck. The lid at angle th runs along
// duoLidDir(th) and its screen faces duoLidNormal(th).
static float2 duoLidDir(float th) { return float2(cos(th), sin(th)); }
static float2 duoLidNormal(float th) { return float2(sin(th), -cos(th)); }

// A glass pixel (lateral x and height h, in screen heights, on a lid
// drawn at thE) -> the picture uv a seated eye saw behind it on the
// resting lid. `valid` is false where the eye is behind either plane.
static float2 duoHeldUV(float x, float h, float thE, constant FoldParams &p,
                        thread bool &valid) {
    float2 E = float2(p.eyeF, p.eyeU);
    float2 u0 = duoLidDir(p.thetaRef);
    float2 n0 = duoLidNormal(p.thetaRef);
    float2 W = h * duoLidDir(thE);
    float en0 = dot(E, n0);
    float den = dot(W - E, n0);
    valid = en0 > 0.0 && dot(E, duoLidNormal(thE)) > 0.0 && den < -1e-4;
    float t = -en0 / den;
    float2 hit = E + t * (W - E);
    return float2(t * x / p.aspect + 0.5, 1.0 - dot(hit, u0));
}

// One pyramid level read as a cubic B-spline through four bilinear taps.
// A single bilinear tap of a decimated level draws the blur as a chain
// of straight ramps; the B-spline draws it as a Gaussian (sigma about
// 0.82 * 2^L base pixels). `shift` undoes MPS's decimation, which keeps
// the even samples and so slides level L right and down by
// (2^L - 1) / 2 base pixels.
static float3 duoLevel(texture2d<float> pyr, sampler s, float2 uv, float lvl, float shift) {
    uint l = uint(lvl);
    float2 size = float2(pyr.get_width(l), pyr.get_height(l));
    float2 base = float2(pyr.get_width(0), pyr.get_height(0));
    uv += shift * (exp2(lvl) - 1.0) * 0.5 / base;
    float2 q = uv * size - 0.5;
    float2 f = fract(q);
    float2 i = q - f;
    float2 f2 = f * f;
    float2 f3 = f2 * f;
    float2 w0 = (1.0 - 3.0 * f + 3.0 * f2 - f3) / 6.0;
    float2 w1 = (4.0 - 6.0 * f2 + 3.0 * f3) / 6.0;
    float2 w2 = (1.0 + 3.0 * f + 3.0 * f2 - 3.0 * f3) / 6.0;
    float2 w3 = f3 / 6.0;
    float2 g0 = w0 + w1;
    float2 g1 = w2 + w3;
    float2 h0 = (i - 0.5 + w1 / g0) / size;
    float2 h1 = (i + 1.5 + w3 / g1) / size;
    float3 a = pyr.sample(s, float2(h0.x, h0.y), level(lvl)).rgb;
    float3 b = pyr.sample(s, float2(h1.x, h0.y), level(lvl)).rgb;
    float3 c = pyr.sample(s, float2(h0.x, h1.y), level(lvl)).rgb;
    float3 d = pyr.sample(s, float2(h1.x, h1.y), level(lvl)).rgb;
    return g0.y * (g0.x * a + g1.x * b) + g1.y * (g0.x * c + g1.x * d);
}

fragment float4 duoFragment(FoldOut in [[stage_in]],
                            texture2d<float> pyramid [[texture(0)]],
                            constant FoldParams &p [[buffer(0)]],
                            sampler sampl [[sampler(0)]]) {
    if (p.blackout > 0.5) { return float4(0.0, 0.0, 0.0, 1.0); }
    float h = 1.0 - in.uv.y;
    float x = (in.uv.x - 0.5) * p.aspect;
    float thE = p.thetaRef - clamp(p.hold, 0.0, 1.0) * (p.thetaRef - p.theta);
    bool valid;
    float2 src = duoHeldUV(x, h, thE, p, valid);
    if (!valid) { return float4(0.0, 0.0, 0.0, 1.0); }
    float2 tuv = (src - 0.5) * p.cover + 0.5;
    // Blur and darkening follow the PICTURE's rows, not the glass: e is
    // 0 at the hinge row and 1 at the far edge.
    float e = clamp(1.0 - src.y, 0.0, 1.0);
    float sigma = p.blurMax * p.motion * pow(e, 1.35);
    // Pyramid level L read as a B-spline carries sigma ~= 0.82 * 2^L
    // base pixels; between levels the two reads blend. Under a level of
    // blur the base is read as it is, so a still picture stays exact.
    float sigmaPx = sigma * p.imageSize.y;
    float lod = clamp(log2(max(sigmaPx, 1e-4) / 0.82), 0.0, max(0.0, p.lodCount - 1.0));
    float l0 = floor(lod);
    float fr = lod - l0;
    float3 c = l0 < 0.5 ? pyramid.sample(sampl, tuv, level(0.0)).rgb
                        : duoLevel(pyramid, sampl, tuv, l0, p.pyramidShift);
    if (fr > 0.001) {
        float l1 = min(l0 + 1.0, max(0.0, p.lodCount - 1.0));
        c = mix(c, duoLevel(pyramid, sampl, tuv, l1, p.pyramidShift), fr);
    }
    // The picture's border feathers over its own defocus, outward only
    // while it is sharp, so the resting frame is the desktop exactly.
    float2 inner = float2(2.5 * sigma / p.aspect, 2.5 * sigma) * p.cover;
    float2 outer = max(max(fwidth(tuv), float2(0.5 / p.imageSize.y)), inner);
    float2 cov = smoothstep(-outer, inner, tuv)
               * (1.0 - smoothstep(1.0 - inner, 1.0 + outer, tuv));
    // The hinge-side fifth never darkens; past it the gain takes the
    // far edge to black once the motion is under way.
    float g = clamp((e - 0.2) / 0.8, 0.0, 1.0);
    float dark = min(1.0, p.darkGain * p.motion * pow(g, 1.35));
    c *= cov.x * cov.y * (1.0 - dark) * (1.0 - clamp(p.endFade, 0.0, 1.0));
    return float4(c, 1.0);
}
"""

    /// True when the encode has what it needs: nothing for the blackout,
    /// the pyramid for the Duo, the full texture for the Room.
    var canDraw: Bool {
        if params.blackout > 0.5 { return true }
        return look == .duo ? duoPyramid != nil : fullTexture != nil
    }

    /// The colour the pass clears to: black for the Duo and the
    /// blackout, the room's void for the Room.
    private var clearColor: MTLClearColor {
        if look == .duo || params.blackout > 0.5 {
            return MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        }
        let f = Double(max(0, min(1, params.frost)))
        return MTLClearColor(
            red: 0.012 + (0.72 * 0.88 - 0.012) * f,
            green: 0.02 + (0.75 * 0.88 - 0.02) * f,
            blue: 0.032 + (0.79 * 0.88 - 0.032) * f, alpha: 1)
    }

    /// The one encode both draw paths share: uniforms from `params`,
    /// aspect/cover fitted to the drawable, one fullscreen triangle.
    /// Bucket slots without a live texture bind the transparent dummy.
    /// The blackout encodes nothing: the pass's black clear is the frame.
    private func encodeFold(into encoder: MTLRenderCommandEncoder, aspect: CGFloat) {
        var p = params
        p.aspect = Float(aspect)
        let cx = max(1, p.aspect / p.texAspect)
        let cy = max(1, p.texAspect / p.aspect)
        p.cover = .init(cx, cy)
        if p.blackout > 0.5 { return }
        if look == .duo {
            encoder.setRenderPipelineState(duoPipeline)
            encoder.setFragmentTexture(duoPyramid, index: 0)
            encoder.setFragmentSamplerState(sampler, index: 0)
            encoder.setFragmentBytes(&p, length: MemoryLayout<Params>.stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            return
        }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(fullTexture, index: 0)
        for i in 0..<PortalDepth.bucketCount {
            let bucket = i < bucketTextures.count ? bucketTextures[i] : dummyTexture
            encoder.setFragmentTexture(bucket, index: 1 + i)
        }
        encoder.setFragmentTexture(farTexture ?? fullTexture, index: 4)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.setFragmentBytes(&p, length: MemoryLayout<Params>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    }

    /// Renders the room into an offscreen texture — the proof harness
    /// and tests draw without an MTKView. Synchronous: waits for the
    /// GPU before returning, and returns false on any failure.
    @discardableResult
    func render(to target: MTLTexture, size: CGSize) -> Bool {
        guard canDraw,
              let command = queue.makeCommandBuffer() else { return false }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        // The shader only paints where the room covers; the clear colour
        // is the same void the fragment mixes in at the edge — the dark
        // room at frost 0, the milk a shade deeper at frost 1 — and black
        // for the Duo and the blackout.
        pass.colorAttachments[0].clearColor = clearColor
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return false }
        encodeFold(into: encoder, aspect: size.width / max(1, size.height))
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
            view.clearColor = clearColor
            guard canDraw,
                  let pass = view.currentRenderPassDescriptor,
                  let drawable = view.currentDrawable,
                  let command = queue.makeCommandBuffer(),
                  let encoder = command.makeRenderCommandEncoder(descriptor: pass) else {
                inFlight.signal()
                if !canDraw {
                    foldLogThrottled("draw: no texture for the look — overlay would paint clear")
                }
                return
            }
            encodeFold(into: encoder,
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
