import Foundation
import AVFoundation
import CoreImage
import CoreGraphics

enum ConvertError: LocalizedError {
    case noVideoTrack
    case readerFailed(String)
    case writerFailed(String)
    case poolUnavailable
    case unknown(String)

    var errorDescription: String? {
        switch self {
        case .noVideoTrack:
            return "这个文件里没有视频轨道，换一个试试"
        case .readerFailed(let s):
            return "读取失败：" + s
        case .writerFailed(let s):
            return "写入失败：" + s
        case .poolUnavailable:
            return "编码器没有给出可用的画面缓冲"
        case .unknown(let s):
            return s
        }
    }
}

/// 运行日志。手机上出问题时，界面里会把这几十行显示出来、可以一键复制，
/// 不用连电脑也能看出卡在哪一步。
enum Diag {
    private static var lines: [String] = []
    private static let lock = NSLock()
    private static let started = Date()

    static func add(_ s: String) {
        lock.lock()
        lines.append(String(format: "[%.1fs] ", Date().timeIntervalSince(started)) + s)
        lock.unlock()
    }

    static func dump() -> String {
        lock.lock()
        let s = lines.suffix(30).joined(separator: "\n")
        lock.unlock()
        return s
    }

    static func reset() {
        lock.lock()
        lines.removeAll()
        lock.unlock()
    }
}

/// 把一条视频转成标准尺寸：竖版 1080x1920、横版 1920x1080。
/// 非标准比例不拉伸不裁切，用同画面的模糊放大版做背景补边。
/// 不足 60 秒的循环补齐（规则与安卓版一致），超过 60 秒的保持原长。
///
/// ## 为什么是两段式
///
/// 真机上"一个写入器连续解码写多遍"这条路走不通：系统的解码服务（mediaserverd）
/// 会偶尔中途崩一次，报 -11819。更麻烦的是它崩的时候，写入器里的硬件编码器
/// 往往一起死了（之后 adaptor.pixelBufferPool 变 nil，报"编码器没有给出可用的画面缓冲"），
/// 写入器救不回来，没法接着往下写。
///
/// 所以改成：
/// 1. **第一段**：源视频只解码一遍 → 编成一条标准尺寸的短片段。
///    崩了就把写入器也整套换新、从头重来（单遍只要一两秒，损失很小）。
/// 2. **第二段**：把这条片段**原样复制** N 遍拼成 60 秒。
///    这一步用直通（outputSettings = nil），只搬压缩数据包、不解码不重绘，
///    不碰解码器和编码器，稳定性完全不同；顺带还快，源片只解一次码。
final class VideoConverter {

    /// 如果真机上发现画面上下颠倒，把这里改成 true（只影响竖直方向，不影响左右）
    private static let verticalFlip = false

    /// 目标总时长（秒）
    private static let limitSeconds = 60.0

    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private let queue = DispatchQueue(label: "com.bh.dayan.convert", qos: .userInitiated)

    func convert(source: URL,
                 progress: @escaping (Double) -> Void,
                 completion: @escaping (Result<URL, Error>) -> Void) {
        queue.async {
            Diag.reset()
            do {
                let out = try self.run(source: source, progress: progress)
                DispatchQueue.main.async { completion(.success(out)) }
            } catch {
                Diag.add("失败：" + error.localizedDescription)
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    // MARK: - 主流程

    private func run(source: URL, progress: @escaping (Double) -> Void) throws -> URL {
        let probe = AVURLAsset(url: source)
        guard let track = probe.tracks(withMediaType: .video).first else {
            throw ConvertError.noVideoTrack
        }

        var fps = Double(track.nominalFrameRate)
        if fps < 20 || fps > 61 { fps = 30 }
        fps = fps.rounded()

        let seconds = CMTimeGetSeconds(probe.duration)
        guard seconds.isFinite && seconds > 0 else {
            throw ConvertError.unknown("读不到视频时长")
        }

        // ---- 循环规则（与安卓版一致）----
        // 15 秒 → 4 遍 = 60 秒；20 秒 → 3 遍；25 秒 → 3 遍 75 秒裁到 60 秒；
        // 本来就 ≥60 秒的保持原长。留 0.5 秒余量，14.97 秒不会算成 5 遍。
        let limit = VideoConverter.limitSeconds
        var loops = 1
        if seconds < limit - 0.5 {
            loops = max(2, Int(ceil((limit - 0.5) / seconds)))
        }
        let targetSeconds = loops > 1 ? min(seconds * Double(loops), limit) : seconds
        let passFrames = max(1, Int((seconds * fps).rounded()))

        // ---- 方向与目标尺寸 ----
        let rect = CGRect(origin: .zero, size: track.naturalSize).applying(track.preferredTransform)
        let displayW = abs(rect.width)
        let displayH = abs(rect.height)
        guard displayW > 1 && displayH > 1 else {
            throw ConvertError.noVideoTrack
        }
        let portrait = displayH >= displayW
        let outW = portrait ? 1080 : 1920
        let outH = portrait ? 1920 : 1080

        // 源片本来就是这个尺寸、而且没有旋转时，第一段不用重绘画面，
        // 解码出来直接交给编码器，又快又省
        let t = track.preferredTransform
        let identity = abs(t.a - 1) < 0.001 && abs(t.b) < 0.001
            && abs(t.c) < 0.001 && abs(t.d - 1) < 0.001
        let needRender = !(identity
            && Int(displayW.rounded()) == outW
            && Int(displayH.rounded()) == outH)

        Diag.add("源 \(String(format: "%.2f", seconds)) 秒 / \(Int(fps)) 帧 / 循环 \(loops) 遍 / 目标 \(String(format: "%.1f", targetSeconds)) 秒")
        Diag.add("画面 \(Int(displayW))x\(Int(displayH)) → \(outW)x\(outH)"
                 + (needRender ? "（需要重绘）" : "（尺寸已达标，直接转码）"))

        // ================= 第一段：源视频 → 标准尺寸片段（只解码一遍） =================
        let segURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("dayan_seg_\(UUID().uuidString).mp4")

        var lastError: Error?
        var segDone = false
        for attempt in 1...3 {
            if attempt > 1 {
                let wait = Double(attempt - 1) * 1.5
                Diag.add("等 \(String(format: "%.1f", wait)) 秒让系统解码服务恢复，换全新解码器从头上重来")
                Thread.sleep(forTimeInterval: wait)
            }
            do {
                try autoreleasepool {
                    try self.encodeSegment(source: source,
                                           to: segURL,
                                           fps: fps,
                                           passFrames: passFrames,
                                           outW: outW,
                                           outH: outH,
                                           needRender: needRender,
                                           displaySize: CGSize(width: displayW, height: displayH),
                                           transform: t,
                                           progress: { p in progress(p * 0.3) })
                }
                segDone = true
                break
            } catch {
                Diag.add("第一段第 \(attempt) 次失败：" + error.localizedDescription)
                lastError = error
                try? FileManager.default.removeItem(at: segURL)
            }
        }
        guard segDone else {
            throw lastError ?? ConvertError.unknown("第一段失败")
        }

        // 源时长本来就够，不用循环，片段就是成品
        if loops == 1 {
            progress(1.0)
            Diag.add("时长已够 \(Int(limit)) 秒，不需要循环")
            return segURL
        }

        // ================= 第二段：把片段原样复制 N 遍（纯封装，不解码） =================
        let finalURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("dayan_out_\(UUID().uuidString).mp4")
        var finalDone = false
        for attempt in 1...3 {
            if attempt > 1 {
                Thread.sleep(forTimeInterval: 1.0)
                Diag.add("复制阶段重来（第 \(attempt) 次）")
            }
            do {
                try self.assemble(segment: segURL,
                                  to: finalURL,
                                  loops: loops,
                                  targetSeconds: targetSeconds,
                                  fps: fps,
                                  progress: { p in progress(0.3 + 0.7 * p) })
                finalDone = true
                break
            } catch {
                Diag.add("复制阶段第 \(attempt) 次失败：" + error.localizedDescription)
                lastError = error
                try? FileManager.default.removeItem(at: finalURL)
            }
        }
        try? FileManager.default.removeItem(at: segURL)
        guard finalDone else {
            throw lastError ?? ConvertError.unknown("复制阶段失败")
        }

        progress(1.0)
        return finalURL
    }

    // MARK: - 第一段：解码 + （重绘）+ 编码

    private func encodeSegment(source: URL,
                               to outURL: URL,
                               fps: Double,
                               passFrames: Int,
                               outW: Int,
                               outH: Int,
                               needRender: Bool,
                               displaySize: CGSize,
                               transform: CGAffineTransform,
                               progress: @escaping (Double) -> Void) throws {
        try? FileManager.default.removeItem(at: outURL)

        // 每次尝试都是全新的 asset / reader / writer，不复用任何旧对象
        let asset = AVURLAsset(url: source)
        guard let videoTrack = asset.tracks(withMediaType: .video).first else {
            throw ConvertError.noVideoTrack
        }

        let writer = try AVAssetWriter(outputURL: outURL, fileType: .mp4)

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: outW,
            AVVideoHeightKey: outH,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 12_000_000,
                AVVideoMaxKeyFrameIntervalKey: Int(fps) * 2,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoExpectedSourceFrameRateKey: Int(fps)
            ]
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: outW,
                kCVPixelBufferHeightKey as String: outH
            ]
        )
        guard writer.canAdd(videoInput) else {
            throw ConvertError.writerFailed("无法挂载视频输入")
        }
        writer.add(videoInput)

        var audioInput: AVAssetWriterInput?
        if !asset.tracks(withMediaType: .audio).isEmpty {
            let ai = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVNumberOfChannelsKey: 2,
                    AVSampleRateKey: 44100,
                    AVEncoderBitRateKey: 192_000
                ]
            )
            ai.expectsMediaDataInRealTime = false
            if writer.canAdd(ai) {
                writer.add(ai)
                audioInput = ai
            }
        }

        guard writer.startWriting() else {
            throw ConvertError.writerFailed(explain(writer.error, fallback: "启动写入失败"))
        }
        writer.startSession(atSourceTime: .zero)
        Diag.add("第一段：写入器已启动，音轨=" + (audioInput == nil ? "无" : "有"))

        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: .zero, duration: asset.duration)

        let vOut = AVAssetReaderTrackOutput(
            track: videoTrack,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        )
        guard reader.canAdd(vOut) else {
            throw ConvertError.readerFailed("无法挂载视频输出")
        }
        reader.add(vOut)

        var aOut: AVAssetReaderTrackOutput?
        if audioInput != nil, let audioTrack = asset.tracks(withMediaType: .audio).first {
            let ao = AVAssetReaderTrackOutput(
                track: audioTrack,
                outputSettings: [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: 44100,
                    AVNumberOfChannelsKey: 2,
                    AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsNonInterleaved: false
                ]
            )
            if reader.canAdd(ao) {
                reader.add(ao)
                aOut = ao
            }
        }

        guard reader.startReading() else {
            throw ConvertError.readerFailed(explain(reader.error, fallback: "启动读取失败"))
        }

        var frameIndex = 0
        var videoDone = false
        var audioDone = (aOut == nil)
        var idle = 0
        var wroteAnyFrame = false
        var lastReport = Date.distantPast

        while (!videoDone || !audioDone) && frameIndex < passFrames {
            var didSomething = false

            if !videoDone && videoInput.isReadyForMoreMediaData {
                if let sample = vOut.copyNextSampleBuffer() {
                    didSomething = true
                    let pts = CMTime(seconds: Double(frameIndex) / fps, preferredTimescale: 600)
                    if needRender {
                        if let imageBuffer = CMSampleBufferGetImageBuffer(sample) {
                            guard let pool = adaptor.pixelBufferPool else {
                                throw ConvertError.poolUnavailable
                            }
                            var outBuffer: CVPixelBuffer?
                            _ = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &outBuffer)
                            guard let ob = outBuffer else {
                                throw ConvertError.poolUnavailable
                            }
                            render(source: imageBuffer,
                                   destination: ob,
                                   displaySize: displaySize,
                                   transform: transform,
                                   outW: outW,
                                   outH: outH)
                            if adaptor.append(ob, withPresentationTime: pts) {
                                wroteAnyFrame = true
                            }
                        }
                    } else if let imageBuffer = CMSampleBufferGetImageBuffer(sample) {
                        // 尺寸已达标，解码出来的画面直接交给编码器
                        if adaptor.append(imageBuffer, withPresentationTime: pts) {
                            wroteAnyFrame = true
                        }
                    }
                    frameIndex += 1

                    let now = Date()
                    if now.timeIntervalSince(lastReport) > 0.2 {
                        lastReport = now
                        let p = min(1.0, Double(frameIndex) / Double(passFrames))
                        DispatchQueue.main.async { progress(p) }
                    }
                } else {
                    videoDone = true
                }
            }

            if !audioDone, let ao = aOut, let ai = audioInput, ai.isReadyForMoreMediaData {
                if let sample = ao.copyNextSampleBuffer() {
                    didSomething = true
                    if !ai.append(sample) {
                        audioDone = true
                    }
                } else {
                    audioDone = true
                }
            }

            if reader.status == .failed {
                throw ConvertError.readerFailed(explain(reader.error, fallback: "读取中断"))
            }
            if writer.status == .failed {
                throw ConvertError.writerFailed(explain(writer.error, fallback: "写入中断"))
            }

            if !didSomething {
                idle += 1
                if idle > 4000 {
                    throw ConvertError.writerFailed("编码器长时间不接受数据，可能是这个尺寸不被支持")
                }
                Thread.sleep(forTimeInterval: 0.003)
            } else {
                idle = 0
            }
        }

        reader.cancelReading()
        videoInput.markAsFinished()
        audioInput?.markAsFinished()

        guard wroteAnyFrame else {
            writer.cancelWriting()
            throw ConvertError.unknown("一帧都没有处理成功，可能是画面尺寸异常")
        }

        Diag.add("第一段：写进 \(frameIndex) 帧，开始收尾")
        let sem = DispatchSemaphore(value: 0)
        writer.finishWriting { sem.signal() }
        sem.wait()

        guard writer.status == .completed else {
            throw ConvertError.writerFailed(explain(writer.error, fallback: "片段收尾失败"))
        }
        Diag.add("第一段完成")
    }

    // MARK: - 第二段：直通复制（不解码）

    private func assemble(segment: URL,
                          to outURL: URL,
                          loops: Int,
                          targetSeconds: Double,
                          fps: Double,
                          progress: @escaping (Double) -> Void) throws {
        try? FileManager.default.removeItem(at: outURL)

        let segAsset = AVURLAsset(url: segment)
        guard let segVideo = segAsset.tracks(withMediaType: .video).first else {
            throw ConvertError.noVideoTrack
        }
        let segAudio = segAsset.tracks(withMediaType: .audio).first
        let segSeconds = CMTimeGetSeconds(segAsset.duration)
        guard segSeconds.isFinite && segSeconds > 0.05 else {
            throw ConvertError.unknown("片段时长为 0")
        }
        Diag.add("第二段：复制 \(loops) 遍，每遍 \(String(format: "%.2f", segSeconds)) 秒")

        let writer = try AVAssetWriter(outputURL: outURL, fileType: .mp4)

        // outputSettings = nil 就是直通：数据包原样搬运，不碰解码器也不碰编码器
        let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: nil)
        vIn.expectsMediaDataInRealTime = false
        guard writer.canAdd(vIn) else {
            throw ConvertError.writerFailed("无法挂载视频直通")
        }
        writer.add(vIn)

        var aIn: AVAssetWriterInput?
        if segAudio != nil {
            let ai = AVAssetWriterInput(mediaType: .audio, outputSettings: nil)
            ai.expectsMediaDataInRealTime = false
            if writer.canAdd(ai) {
                writer.add(ai)
                aIn = ai
            }
        }

        guard writer.startWriting() else {
            throw ConvertError.writerFailed(explain(writer.error, fallback: "直通写入启动失败"))
        }
        writer.startSession(atSourceTime: .zero)

        let videoFallback = CMTime(value: 1, timescale: CMTimeScale(max(1, Int32(fps))))

        for pass in 0..<loops {
            let offset = CMTime(seconds: Double(pass) * segSeconds, preferredTimescale: 600)

            let reader = try AVAssetReader(asset: segAsset)
            let vOut = AVAssetReaderTrackOutput(track: segVideo, outputSettings: nil)
            guard reader.canAdd(vOut) else {
                throw ConvertError.readerFailed("无法挂载视频直通读取")
            }
            reader.add(vOut)

            var aOut: AVAssetReaderTrackOutput?
            if let at = segAudio {
                let ao = AVAssetReaderTrackOutput(track: at, outputSettings: nil)
                if reader.canAdd(ao) {
                    reader.add(ao)
                    aOut = ao
                }
            }

            guard reader.startReading() else {
                throw ConvertError.readerFailed(explain(reader.error, fallback: "直通读取启动失败"))
            }

            var videoDone = false
            var audioDone = (aOut == nil)
            var cut = false
            var idle = 0

            while (!videoDone || !audioDone) && !cut {
                var didSomething = false

                if !videoDone && vIn.isReadyForMoreMediaData {
                    if let s = vOut.copyNextSampleBuffer() {
                        didSomething = true
                        let pts = CMTimeAdd(CMSampleBufferGetPresentationTimeStamp(s), offset)
                        if CMTimeGetSeconds(pts) >= targetSeconds - 0.0001 {
                            cut = true
                        } else if CMTimeGetSeconds(pts) >= -0.001 {
                            if let outSample = retimed(s, pts: pts, fallbackDuration: videoFallback) {
                                if !vIn.append(outSample) {
                                    videoDone = true
                                }
                            }
                        }
                    } else {
                        videoDone = true
                    }
                }

                if !cut, !audioDone, let ao = aOut, let ai = aIn, ai.isReadyForMoreMediaData {
                    if let s = ao.copyNextSampleBuffer() {
                        didSomething = true
                        let pts = CMTimeAdd(CMSampleBufferGetPresentationTimeStamp(s), offset)
                        if CMTimeGetSeconds(pts) >= targetSeconds - 0.0001 {
                            cut = true
                        } else if CMTimeGetSeconds(pts) >= -0.001 {
                            let n = max(1, CMSampleBufferGetNumSamples(s))
                            let audioFallback = CMTime(value: CMTimeValue(n), timescale: 44100)
                            if let outSample = retimed(s, pts: pts, fallbackDuration: audioFallback) {
                                if !ai.append(outSample) {
                                    audioDone = true
                                }
                            }
                        }
                    } else {
                        audioDone = true
                    }
                }

                if reader.status == .failed {
                    throw ConvertError.readerFailed(explain(reader.error, fallback: "直通读取中断"))
                }
                if writer.status == .failed {
                    throw ConvertError.writerFailed(explain(writer.error, fallback: "直通写入中断"))
                }

                if !didSomething {
                    idle += 1
                    if idle > 4000 {
                        throw ConvertError.writerFailed("复制阶段长时间没有数据，可能片段有问题")
                    }
                    Thread.sleep(forTimeInterval: 0.003)
                } else {
                    idle = 0
                }
            }

            reader.cancelReading()
            Diag.add("第二段：第 \(pass + 1) 遍复制完成")
            progress(Double(pass + 1) / Double(loops))
            if cut { break }
        }

        vIn.markAsFinished()
        aIn?.markAsFinished()

        Diag.add("第二段：开始收尾")
        let sem = DispatchSemaphore(value: 0)
        writer.finishWriting { sem.signal() }
        sem.wait()

        guard writer.status == .completed else {
            throw ConvertError.writerFailed(explain(writer.error, fallback: "收尾失败"))
        }
        Diag.add("第二段完成，总时长约 \(String(format: "%.1f", min(Double(loops) * segSeconds, targetSeconds))) 秒")
    }

    // MARK: - 工具

    /// 复制一个采样缓冲，只换时间戳（时长和内容原样保留）。
    /// 直通复制时用这个把每一遍的数据包挪到对应的时间位置。
    private func retimed(_ sample: CMSampleBuffer, pts: CMTime, fallbackDuration: CMTime) -> CMSampleBuffer? {
        var dur = CMSampleBufferGetDuration(sample)
        if !dur.isValid || dur.seconds <= 0 {
            dur = fallbackDuration
        }
        var timing = CMSampleTimingInfo(duration: dur,
                                        presentationTimeStamp: pts,
                                        decodeTimeStamp: .invalid)
        var out: CMSampleBuffer?
        let st = CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault,
                                                       sampleBuffer: sample,
                                                       sampleTimingEntryCount: 1,
                                                       sampleTimingArray: &timing,
                                                       sampleBufferOut: &out)
        return st == noErr ? out : nil
    }

    /// 把 AVFoundation 的错误翻成人话，并带上错误码，方便排查
    private func explain(_ error: Error?, fallback: String) -> String {
        guard let e = error else { return fallback }
        let ns = e as NSError
        var s = ns.localizedDescription
        if let under = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
            s += "（\(under.domain) \(under.code)）"
        } else {
            s += "（\(ns.domain) \(ns.code)）"
        }
        if ns.code == -11819 || (ns.userInfo[NSUnderlyingErrorKey] as? NSError)?.code == -11819 {
            s += "：系统解码服务崩了，换新解码器可以救"
        }
        return s
    }

    // MARK: - 单帧合成

    private func render(source: CVPixelBuffer,
                        destination: CVPixelBuffer,
                        displaySize: CGSize,
                        transform: CGAffineTransform,
                        outW: Int,
                        outH: Int) {
        let outRect = CGRect(x: 0, y: 0, width: outW, height: outH)
        let W = CGFloat(outW)
        let H = CGFloat(outH)
        let dw = displaySize.width
        let dh = displaySize.height

        // 原始帧按方向变换摆正，并把原点归到 (0,0)
        var image = CIImage(cvPixelBuffer: source)
        image = image.transformed(by: transform)
        let ex = image.extent
        image = image.transformed(by: CGAffineTransform(translationX: -ex.origin.x,
                                                       y: -ex.origin.y))

        // 背景：先等比放大到铺满目标尺寸
        let bgScale = max(W / dw, H / dh)
        var bg = image.transformed(by: CGAffineTransform(scaleX: bgScale, y: bgScale))
        let bgW = dw * bgScale
        let bgH = dh * bgScale
        bg = bg.transformed(by: CGAffineTransform(translationX: (W - bgW) / 2.0,
                                                  y: (H - bgH) / 2.0))
        bg = bg.cropped(to: outRect)

        // 缩到四分之一再模糊，速度比原尺寸直接模糊快一个数量级，
        // 半径 5 放大回原尺寸后约等于 20，观感和电脑版一致
        let s: CGFloat = 0.25
        var small = bg.transformed(by: CGAffineTransform(scaleX: s, y: s))
        small = small.clampedToExtent()
        small = small.applyingFilter("CIGaussianBlur",
                                     parameters: [kCIInputRadiusKey: 5.0])
        small = small.cropped(to: CGRect(x: 0, y: 0, width: W * s, height: H * s))
        let blurred = small.transformed(by: CGAffineTransform(scaleX: 1.0 / s, y: 1.0 / s))

        // 前景：完整装进目标尺寸，等比缩放不裁切
        let fgScale = min(W / dw, H / dh)
        var fg = image.transformed(by: CGAffineTransform(scaleX: fgScale, y: fgScale))
        let fgW = dw * fgScale
        let fgH = dh * fgScale
        fg = fg.transformed(by: CGAffineTransform(translationX: (W - fgW) / 2.0,
                                                  y: (H - fgH) / 2.0))

        var composed = fg.composited(over: blurred).cropped(to: outRect)
        if VideoConverter.verticalFlip {
            composed = composed
                .transformed(by: CGAffineTransform(scaleX: 1, y: -1))
                .transformed(by: CGAffineTransform(translationX: 0, y: H))
        }
        ciContext.render(composed,
                         to: destination,
                         bounds: outRect,
                         colorSpace: CGColorSpaceCreateDeviceRGB())
    }
}
