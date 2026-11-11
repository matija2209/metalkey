// metalkey: GPU green-screen keyer for Apple Silicon. A Metal port of an FFmpeg
// dominance-key pipeline (see README), with a zoom-out geometry for vertical (9:16) output.
//
// Decode (VideoToolbox via AVAssetReader) -> Metal compute (geometry, matte, blur, despill,
// composite, RGB->NV12) -> hardware H.264 encode (AVAssetWriter) -> ffmpeg -c copy remux of
// the source audio (bit-exact) and subtitles.
import AVFoundation
import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import ImageIO
import Metal
import VideoToolbox

func die(_ msg: String) -> Never {
    FileHandle.standardError.write(("metalkey: " + msg + "\n").data(using: .utf8)!)
    exit(1)
}

let shaderSource = String(decoding: PackageResources.Shaders_metal, as: UTF8.self)

let usage = """
usage: metalkey <in.mp4> <bg.png|bg.jpg|bg.mp4|bg.mov> <out.mp4> [options]
       metalkey <in.mp4> --preview <out.png> [--at S] [options]
  --lo N            dominance needed before a pixel starts to vanish (default 12, 0-255 scale)
  --gain N          opaque -> transparent steepness (default 12)
  --out-size WxH    output size (default: source size)
  --zoom Z          zoom-out percent for --out-size (default 100). The window is
                    base*100/Z wide and srcH*100/Z high, bottom-anchored; the part above
                    the source becomes background
  --center-x N      window centre in source pixels (default: source centre)
  --garbage x0:y0:x1:y1   box forced transparent, source pixels; repeatable, or several
                    boxes separated by spaces. Default: $GARBAGE
  --grain N         moving noise on a still background (default $GRAIN or 5; 0 = off;
                    never applied to video backgrounds)
  --start S         start time in seconds (default 0)
  --length S        seconds to render (default 0 = to the end)
  --subs file.srt   subtitle track to mux instead of the source's own subtitle stream
  --no-subs         do not carry any subtitle track
  --bitrate M       H.264 average bitrate in Mbit/s (default: 0.12 bits/pixel x fps)
  --sigma S         matte blur sigma (default 1.2)
  --video-only      skip the ffmpeg remux; write the video stream only
  --chroma-loc L    4:2:0 chroma siting of the source: center (default; what FFmpeg's
                    swscale assumes) or left (the H.264 tag)
  --preview F.png   render one keyed frame on magenta to F.png (for tuning --lo/--gain);
                    no background or output video needed
  --at S            time of the --preview frame in seconds (default 3, clamped to the clip)
"""

// MARK: options
var positional: [String] = []
var lo: Float = 12, gain: Float = 12, sigma: Float = 1.2
var zoom: Double = 100
var centerX: Double? = nil
var outW: Int? = nil, outH: Int? = nil
var boxes: [[Float]] = []
var grain: Float = Float(ProcessInfo.processInfo.environment["GRAIN"] ?? "5") ?? 5
var start: Double = 0, length: Double = 0
var subsFile: String? = nil
var noSubs = false
var bitrateMbps: Double? = nil
var videoOnly = false
var chromaCenter = true // swscale default (what the FFmpeg reference effectively does)
var previewPath: String? = nil
var previewAt: Double = 3

func parseBoxes(_ s: String) {
    for b in s.split(separator: " ") where !b.isEmpty {
        let v = b.split(separator: ":").compactMap { Float($0) }
        guard v.count == 4 else { die("bad garbage box \(b), want x0:y0:x1:y1") }
        boxes.append(v)
    }
}
if let g = ProcessInfo.processInfo.environment["GARBAGE"] { parseBoxes(g) }

var argv = Array(CommandLine.arguments.dropFirst())
func next(_ name: String) -> String {
    guard !argv.isEmpty else { die("\(name) needs a value") }
    return argv.removeFirst()
}
while !argv.isEmpty {
    let a = argv.removeFirst()
    switch a {
    case "-h", "--help": print(usage); exit(0)
    case "--lo": lo = Float(next(a)) ?? lo
    case "--gain": gain = Float(next(a)) ?? gain
    case "--sigma": sigma = Float(next(a)) ?? sigma
    case "--zoom": zoom = Double(next(a)) ?? zoom
    case "--center-x": centerX = Double(next(a))
    case "--out-size":
        let v = next(a).lowercased().split(separator: "x").compactMap { Int($0) }
        guard v.count == 2, v[0] % 2 == 0, v[1] % 2 == 0 else { die("--out-size wants even WxH") }
        outW = v[0]; outH = v[1]
    case "--garbage": parseBoxes(next(a))
    case "--grain": grain = Float(next(a)) ?? grain
    case "--start": start = Double(next(a)) ?? 0
    case "--length": length = Double(next(a)) ?? 0
    case "--subs": subsFile = next(a)
    case "--no-subs": noSubs = true
    case "--bitrate": bitrateMbps = Double(next(a))
    case "--video-only": videoOnly = true
    case "--chroma-loc": chromaCenter = next(a) == "center"
    case "--preview": previewPath = next(a)
    case "--at": previewAt = Double(next(a)) ?? previewAt
    default:
        if a.hasPrefix("--") { die("unknown option \(a)\n\(usage)") }
        positional.append(a)
    }
}
let preview = previewPath != nil
guard preview ? positional.count >= 1 : positional.count == 3 else { print(usage); exit(2) }
let inPath = positional[0]
let bgPath = preview ? "" : positional[1], outPath = preview ? previewPath! : positional[2]
if boxes.count > 8 { die("at most 8 garbage boxes") }
let t0 = Date()

// MARK: Metal
guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { die("no Metal device") }
let library: MTLLibrary
do { library = try device.makeLibrary(source: shaderSource, options: nil) } catch { die("shader compile: \(error)") }
func pipeline(_ name: String) -> MTLComputePipelineState {
    guard let f = library.makeFunction(name: name) else { die("no kernel \(name)") }
    do { return try device.makeComputePipelineState(function: f) } catch { die("pipeline \(name): \(error)") }
}
let geomPSO = pipeline("key_geom"), blurPSO = pipeline("blur_h"), compPSO = pipeline("composite"), coverPSO = pipeline("cover")
var cacheOpt: CVMetalTextureCache?
CVMetalTextureCacheCreate(nil, nil, device, nil, &cacheOpt)
guard let texCache = cacheOpt else { die("no CVMetalTextureCache") }

func planeTexture(_ pb: CVPixelBuffer, _ plane: Int, _ fmt: MTLPixelFormat) -> (MTLTexture, CVMetalTexture) {
    let w = CVPixelBufferGetWidthOfPlane(pb, plane), h = CVPixelBufferGetHeightOfPlane(pb, plane)
    var cvt: CVMetalTexture?
    let attrs = [kCVMetalTextureUsage as String: NSNumber(value: MTLTextureUsage([.shaderRead, .shaderWrite]).rawValue)] as CFDictionary
    let r = CVMetalTextureCacheCreateTextureFromImage(nil, texCache, pb, attrs, fmt, w, h, plane, &cvt)
    guard r == kCVReturnSuccess, let c = cvt, let t = CVMetalTextureGetTexture(c) else { die("texture from pixel buffer failed (\(r))") }
    return (t, c)
}
func makeTex(_ w: Int, _ h: Int, _ fmt: MTLPixelFormat) -> MTLTexture {
    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: fmt, width: w, height: h, mipmapped: false)
    d.usage = [.shaderRead, .shaderWrite]
    d.storageMode = .private
    return device.makeTexture(descriptor: d)!
}
func dispatch(_ enc: MTLComputeCommandEncoder, _ pso: MTLComputePipelineState, _ w: Int, _ h: Int) {
    enc.setComputePipelineState(pso)
    let tg = MTLSize(width: 16, height: 16, depth: 1)
    enc.dispatchThreadgroups(MTLSize(width: (w + 15) / 16, height: (h + 15) / 16, depth: 1), threadsPerThreadgroup: tg)
}

// MARK: source
let inURL = URL(fileURLWithPath: inPath)
let asset = AVURLAsset(url: inURL)
guard let vtrack = asset.tracks(withMediaType: .video).first else { die("no video track in \(inPath)") }
let srcW = Int(vtrack.naturalSize.width.rounded()), srcH = Int(vtrack.naturalSize.height.rounded())
let fps = Double(vtrack.nominalFrameRate)
let W = outW ?? srcW, H = outH ?? srcH

// Matrix of the source (BT.709 for HD unless tagged 601)
var Kr: Float = 0.2126, Kb: Float = 0.0722
if let fd = vtrack.formatDescriptions.first {
    let ext = CMFormatDescriptionGetExtension(fd as! CMFormatDescription, extensionKey: kCMFormatDescriptionExtension_YCbCrMatrix) as? String
    if ext == (kCMFormatDescriptionYCbCrMatrix_ITU_R_601_4 as String) { Kr = 0.299; Kb = 0.114 }
}

// Geometry (integer maths of the FFmpeg reference: scale + pad + crop)
let base = Int((Double(srcH) * Double(W) / Double(H)).rounded()) / 2 * 2
let winW = Int(Double(base) * 100 / zoom) / 2 * 2
let winH = Int(Double(srcH) * 100 / zoom) / 2 * 2
let cx = centerX ?? Double(srcW) / 2
// ffmpeg crop on yuv420p rounds x down to even; do the same so framing matches the reference
let winX = (Int(cx) - winW / 2) & ~1
let winY = srcH - winH // bottom-anchored; negative = pad above the frame
if winX < 0 || winX + winW > srcW {
    FileHandle.standardError.write("metalkey: warning: window x \(winX)..\(winX + winW) leaves the \(srcW)px source; the outside is background\n".data(using: .utf8)!)
}

let reader: AVAssetReader
do { reader = try AVAssetReader(asset: asset) } catch { die("reader: \(error)") }
let pbAttrs: [String: Any] = [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
    kCVPixelBufferMetalCompatibilityKey as String: true,
    kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
]
let vout = AVAssetReaderTrackOutput(track: vtrack, outputSettings: pbAttrs)
vout.alwaysCopiesSampleData = false
reader.add(vout)
if preview {
    let dur = asset.duration.seconds
    start = max(0, min(previewAt, dur - 2 / (fps > 0 ? fps : 25)))
    length = 1
    grain = 0
}
let startTime = CMTime(seconds: start, preferredTimescale: 600000)
if start > 0 || length > 0 {
    // a quarter frame early, so the frame exactly at --start is not lost to timescale rounding
    let eps = 0.25 / (fps > 0 ? fps : 25)
    reader.timeRange = CMTimeRange(start: CMTime(seconds: max(0, start - eps), preferredTimescale: 600000),
                                   duration: length > 0 ? CMTime(seconds: length, preferredTimescale: 600000) : .positiveInfinity)
}
guard reader.startReading() else { die("cannot read \(inPath): \(String(describing: reader.error))") }

// MARK: background
let bgExt = (bgPath as NSString).pathExtension.lowercased()
let bgIsVideo = !preview && ["mp4", "mov", "m4v", "webm"].contains(bgExt)
let bgTex = makeTex(W, H, .rgba16Float)

func coverParams(_ bw: Int, _ bh: Int) -> [Float] {
    // ffmpeg: scale=W:H:force_original_aspect_ratio=increase, crop=W:H (centred)
    let s = max(Double(W) / Double(bw), Double(H) / Double(bh))
    let sw = max(W, Int((Double(bw) * s).rounded())), sh = max(H, Int((Double(bh) * s).rounded()))
    return [Float(Double(bw) / Double(sw)), Float(Double(bh) / Double(sh)), Float((sw - W) / 2), Float((sh - H) / 2)]
}
func encodeCover(_ cb: MTLCommandBuffer, _ src: MTLTexture) {
    var p = coverParams(src.width, src.height)
    let enc = cb.makeComputeCommandEncoder()!
    enc.setTexture(src, index: 0); enc.setTexture(bgTex, index: 1)
    enc.setBytes(&p, length: p.count * 4, index: 0)
    dispatch(enc, coverPSO, W, H)
    enc.endEncoding()
}

var bgAsset: AVURLAsset? = nil
var bgReader: AVAssetReader? = nil
var bgOut: AVAssetReaderTrackOutput? = nil
var bgDuration = 0.0, bgLoopOffset = 0.0
var bgCur: (CMSampleBuffer, Double)? = nil, bgNext: (CMSampleBuffer, Double)? = nil
func openBG() {
    guard let a = bgAsset, let t = a.tracks(withMediaType: .video).first else { die("no video in \(bgPath)") }
    let r = try! AVAssetReader(asset: a)
    let o = AVAssetReaderTrackOutput(track: t, outputSettings: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferMetalCompatibilityKey as String: true,
        kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
    ])
    o.alwaysCopiesSampleData = false
    r.add(o)
    guard r.startReading() else { die("cannot read \(bgPath)") }
    bgReader = r; bgOut = o
}
func readBG() -> (CMSampleBuffer, Double)? {
    for _ in 0..<2 {
        if let s = bgOut!.copyNextSampleBuffer(), CMSampleBufferGetImageBuffer(s) != nil {
            return (s, CMSampleBufferGetPresentationTimeStamp(s).seconds + bgLoopOffset)
        }
        bgLoopOffset += bgDuration // loop (ffmpeg -stream_loop -1)
        openBG()
    }
    return nil
}

if preview {
    // solid magenta: the opposite of green, so leftover green, holes and see-through areas show
    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 1, height: 1, mipmapped: false)
    d.usage = [.shaderRead]
    let src = device.makeTexture(descriptor: d)!
    var px: [UInt8] = [255, 0, 255, 255]
    src.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &px, bytesPerRow: 4)
    let cb = queue.makeCommandBuffer()!
    encodeCover(cb, src)
    cb.commit(); cb.waitUntilCompleted()
} else if bgIsVideo {
    grain = 0 // no grain on video backgrounds
    bgAsset = AVURLAsset(url: URL(fileURLWithPath: bgPath))
    bgDuration = bgAsset!.duration.seconds
    openBG()
    bgCur = readBG(); bgNext = readBG()
    guard bgCur != nil else { die("no frames in \(bgPath)") }
} else {
    guard let isrc = CGImageSourceCreateWithURL(URL(fileURLWithPath: bgPath) as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(isrc, 0, nil) else { die("cannot load image \(bgPath)") }
    let iw = img.width, ih = img.height
    // Draw in the image's own colour space so the pixel values are not colour-managed (like ffmpeg)
    let cs = (img.colorSpace?.model == .rgb ? img.colorSpace : nil) ?? CGColorSpace(name: CGColorSpace.sRGB)!
    guard let ctx = CGContext(data: nil, width: iw, height: ih, bitsPerComponent: 8, bytesPerRow: iw * 4, space: cs,
                              bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { die("CGContext") }
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: iw, height: ih))
    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: iw, height: ih, mipmapped: false)
    d.usage = [.shaderRead]
    let src = device.makeTexture(descriptor: d)!
    src.replace(region: MTLRegionMake2D(0, 0, iw, ih), mipmapLevel: 0, withBytes: ctx.data!, bytesPerRow: iw * 4)
    let cb = queue.makeCommandBuffer()!
    encodeCover(cb, src)
    cb.commit(); cb.waitUntilCompleted()
}

// MARK: writer (video only; audio + subtitles are remuxed with ffmpeg -c copy afterwards)
let outURL = URL(fileURLWithPath: outPath)
var writer: AVAssetWriter! = nil
var vin: AVAssetWriterInput! = nil
var adaptor: AVAssetWriterInputPixelBufferAdaptor! = nil
var pool: CVPixelBufferPool! = nil
let videoURL = videoOnly ? outURL : outURL.deletingLastPathComponent().appendingPathComponent(".metalkey-\(getpid())-" + outURL.lastPathComponent)
func setupWriter() {
try? FileManager.default.removeItem(at: videoURL)
do { writer = try AVAssetWriter(outputURL: videoURL, fileType: .mp4) } catch { die("writer: \(error)") }
let bitrate = Int((bitrateMbps.map { $0 * 1_000_000 }) ?? (0.12 * Double(W * H) * (fps > 0 ? fps : 25)))
let vSettings: [String: Any] = [
    AVVideoCodecKey: AVVideoCodecType.h264,
    AVVideoWidthKey: W,
    AVVideoHeightKey: H,
    AVVideoEncoderSpecificationKey: [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: true],
    AVVideoColorPropertiesKey: [
        AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
        AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
    ],
    AVVideoCompressionPropertiesKey: [
        AVVideoAverageBitRateKey: bitrate,
        AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
        AVVideoH264EntropyModeKey: AVVideoH264EntropyModeCABAC,
        AVVideoAllowFrameReorderingKey: true,
        AVVideoExpectedSourceFrameRateKey: fps,
        AVVideoMaxKeyFrameIntervalKey: max(1, Int((fps * 2).rounded())),
    ],
]
vin = AVAssetWriterInput(mediaType: .video, outputSettings: vSettings)
vin.expectsMediaDataInRealTime = false
vin.mediaTimeScale = vtrack.naturalTimeScale
adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: vin, sourcePixelBufferAttributes: [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
    kCVPixelBufferWidthKey as String: W,
    kCVPixelBufferHeightKey as String: H,
    kCVPixelBufferMetalCompatibilityKey as String: true,
    kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
])
writer.add(vin)
guard writer.startWriting() else { die("startWriting: \(String(describing: writer.error))") }
writer.startSession(atSourceTime: .zero)
guard let p = adaptor.pixelBufferPool else { die("no pixel buffer pool") }
pool = p
}
if preview {
    var p: CVPixelBufferPool?
    CVPixelBufferPoolCreate(nil, nil, [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        kCVPixelBufferWidthKey as String: W, kCVPixelBufferHeightKey as String: H,
        kCVPixelBufferMetalCompatibilityKey as String: true,
        kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
    ] as CFDictionary, &p)
    guard let p else { die("no pixel buffer pool") }
    pool = p
} else {
    setupWriter()
}

// MARK: per-frame loop
let fgTex = makeTex(W, H, .rgba16Float)
let tmpTex = makeTex(W, H, .r16Float)
var geomP = [Float](repeating: 0, count: 12 + 32)
geomP[0] = Float(winW) / Float(W); geomP[1] = Float(winH) / Float(H)
geomP[2] = Float(winX); geomP[3] = Float(winY)
geomP[4] = Float(srcW); geomP[5] = Float(srcH)
geomP[6] = lo; geomP[7] = gain; geomP[8] = Kr; geomP[9] = Kb
geomP[10] = Float(boxes.count)
geomP[11] = chromaCenter ? 1 : 0
for (i, b) in boxes.enumerated() { for k in 0..<4 { geomP[12 + 4 * i + k] = b[k] } }

func writePreview(_ pb: CVPixelBuffer) {
    let ci = CIImage(cvPixelBuffer: pb)
    let ctx = CIContext(mtlDevice: device)
    guard let cg = ctx.createCGImage(ci, from: ci.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!),
          let dst = CGImageDestinationCreateWithURL(outURL as CFURL, "public.png" as CFString, 1, nil) else { die("cannot write \(outPath)") }
    CGImageDestinationAddImage(dst, cg, nil)
    guard CGImageDestinationFinalize(dst) else { die("cannot write \(outPath)") }
    print(String(format: "metalkey: preview %dx%d at %.2fs -> %@ (lo %g, gain %g)", W, H, start, outPath, lo, gain))
}

struct InFlight { let cb: MTLCommandBuffer; let out: CVPixelBuffer; let pts: CMTime; let keep: [Any] }
var inflight: [InFlight] = []
var frames = 0
func flushOne() {
    let f = inflight.removeFirst()
    f.cb.waitUntilCompleted()
    if let e = f.cb.error { die("GPU: \(e)") }
    if preview { writePreview(f.out); exit(0) }
    while !vin.isReadyForMoreMediaData { usleep(200) }
    if !adaptor.append(f.out, withPresentationTime: f.pts) { die("append failed: \(String(describing: writer.error))") }
}

while let sb = vout.copyNextSampleBuffer() {
    guard let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
    let pts = CMTimeSubtract(CMSampleBufferGetPresentationTimeStamp(sb), start > 0 ? startTime : .zero)
    let (yT, yC) = planeTexture(pb, 0, .r8Unorm)
    let (cT, cC) = planeTexture(pb, 1, .rg8Unorm)
    var outPB: CVPixelBuffer?
    guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &outPB) == kCVReturnSuccess, let opb = outPB else { die("pool exhausted") }
    CVBufferSetAttachment(opb, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
    CVBufferSetAttachment(opb, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
    CVBufferSetAttachment(opb, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
    CVBufferSetAttachment(opb, kCVImageBufferChromaLocationTopFieldKey, kCVImageBufferChromaLocation_Left, .shouldPropagate)
    let (oyT, oyC) = planeTexture(opb, 0, .r8Unorm)
    let (ocT, ocC) = planeTexture(opb, 1, .rg8Unorm)
    var keep: [Any] = [sb, yC, cC, oyC, ocC]

    let cb = queue.makeCommandBuffer()!
    if bgIsVideo {
        let t = pts.seconds
        while let n = bgNext, n.1 <= t + 1e-6 { bgCur = n; bgNext = readBG() }
        let (bt, bc) = planeTexture(CMSampleBufferGetImageBuffer(bgCur!.0)!, 0, .bgra8Unorm)
        keep.append(bc); keep.append(bgCur!.0)
        encodeCover(cb, bt)
    }
    var enc = cb.makeComputeCommandEncoder()!
    enc.setTexture(yT, index: 0); enc.setTexture(cT, index: 1); enc.setTexture(fgTex, index: 2)
    enc.setBytes(&geomP, length: geomP.count * 4, index: 0)
    dispatch(enc, geomPSO, W, H)
    enc.endEncoding()

    var q: [Float] = [sigma, grain, Float(frames), Kr, Kb, 0.5, 0.0]
    // output is always tagged BT.709
    q[3] = 0.2126; q[4] = 0.0722
    enc = cb.makeComputeCommandEncoder()!
    enc.setTexture(fgTex, index: 0); enc.setTexture(tmpTex, index: 1)
    enc.setBytes(&q, length: q.count * 4, index: 0)
    dispatch(enc, blurPSO, W, H)
    enc.endEncoding()

    enc = cb.makeComputeCommandEncoder()!
    enc.setTexture(fgTex, index: 0); enc.setTexture(tmpTex, index: 1); enc.setTexture(bgTex, index: 2)
    enc.setTexture(oyT, index: 3); enc.setTexture(ocT, index: 4)
    enc.setBytes(&q, length: q.count * 4, index: 0)
    dispatch(enc, compPSO, W / 2, H / 2)
    enc.endEncoding()
    cb.commit()
    inflight.append(InFlight(cb: cb, out: opb, pts: pts, keep: keep))
    frames += 1
    if inflight.count >= 4 { flushOne() }
}
while !inflight.isEmpty { flushOne() }
if preview { die("no frame at \(start)s in \(inPath)") }
if reader.status == .failed { die("decode failed: \(String(describing: reader.error))") }
vin.markAsFinished()
let sem = DispatchSemaphore(value: 0)
writer.finishWriting { sem.signal() }
sem.wait()
guard writer.status == .completed else { die("finishWriting: \(String(describing: writer.error))") }
let tVideo = Date().timeIntervalSince(t0)

// MARK: remux audio (bit-exact copy) and subtitles from the source
if !videoOnly {
    var args = ["-v", "error", "-y", "-i", videoURL.path]
    var cut: [String] = []
    if start > 0 { cut += ["-ss", String(start)] }
    if length > 0 { cut += ["-t", String(length)] }
    args += cut + ["-i", inPath]
    let atrack = asset.tracks(withMediaType: .audio).first
    var isAAC = false
    if let fd = atrack?.formatDescriptions.first {
        isAAC = CMFormatDescriptionGetMediaSubType(fd as! CMFormatDescription) == kAudioFormatMPEG4AAC
    }
    var maps = ["-map", "0:v:0", "-map", "1:a:0?"]
    var codecs = ["-c", "copy"]
    if atrack != nil && !isAAC { codecs += ["-c:a", "aac", "-b:a", "192k"] }
    if let s = subsFile, !noSubs {
        args += cut + ["-i", s]
        maps += ["-map", "2:s:0"]
        codecs += ["-c:s", "mov_text"]
    } else if !noSubs {
        maps += ["-map", "1:s:0?"]
    }
    args += maps + codecs + ["-map_metadata", "1", "-movflags", "+faststart", outPath]
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = ["ffmpeg"] + args
    do { try p.run() } catch { die("cannot run ffmpeg: \(error)") }
    p.waitUntilExit()
    try? FileManager.default.removeItem(at: videoURL)
    if p.terminationStatus != 0 { die("ffmpeg remux failed (\(p.terminationStatus))") }
}
let total = Date().timeIntervalSince(t0)
print(String(format: "metalkey: %d frames %dx%d -> %@ in %.2fs (%.0f fps; video %.2fs, remux %.2fs)",
             frames, W, H, outPath, total, Double(frames) / tVideo, tVideo, total - tVideo))
