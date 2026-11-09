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
/// 循环的实现方式：**不使用 AVMutableComposition，也不做中间导出**。
/// 而是同一个写入器连续写多遍——每一遍开一个新的 AVAssetReader 重新读源文件，
/// 帧号接着往下排、音轨时间轴按段偏移。
///
/// 关于 -11819：真机实测系统的解码服务（mediaserverd）偶尔会在转换中途崩一次。
/// 崩过之后，旧 AVAsset 上的轨道对象就作废了，复用它们重试会立刻再报同样的错。
/// 所以 v0.5 的做法是：读取一旦失败，等系统把解码服务拉起来（1.5 秒起步），
/// 然后**整套换新**（新建 AVURLAsset + AVAssetReader），并从断点处续读——
/// 已经写好的帧不浪费，输出时间轴照常连续。
final class VideoConverter {

    /// 如果真机上发现画面上下颠倒，把这里改成 true（只影响竖直方向，不影响左右）
    private static let verticalFlip = false

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
        let asset = AVURLAsset(url: source)

        guard let videoTrack = asset.tracks(withMediaType: .video).first else {
            throw ConvertError.noVideoTrack
        }

        var fps = Double(videoTrack.nominalFrameRate)
        if fps < 20 || fps > 61 { fps = 30 }
        fps = fps.rounded()

        let seconds = CMTimeGetSeconds(asset.duration)
        guard seconds.isFinite && seconds > 0 else {
            throw ConvertError.unknown("读不到视频时长")
        }

        // ---- 循环规则（与安卓版一致）----
        // 15 秒 → 4 遍 = 60 秒；20 秒 → 3 遍；25 秒 → 3 遍 75 秒裁到 60 秒；
        // 本来就 ≥60 秒的保持原长。留 0.5 秒余量，14.97 秒不会算成 5 遍。
        let targetSeconds = 60.0
        var loops = 1
        if seconds < targetSeconds - 0.5 {
            loops = max(2, Int(ceil((targetSeconds - 0.5) / seconds)))
        }
        let outSeconds = loops > 1 ? min(seconds * Double(loops), targetSeconds) : seconds
        let targetFrames = max(1, Int((outSeconds * fps).rounded()))
        Diag.add("源 \(String(format: "%.2f", seconds)) 秒 / \(Int(fps)) 帧 / 写 \(loops) 遍 / 目标 \(String(format: "%.1f", outSeconds)) 秒 \(targetFrames) 帧")

        // ---- 方向与目标尺寸 ----
        let naturalSize = videoTrack.naturalSize
        let transform = videoTrack.preferredTransform
        let displayRect = CGRect(origin: .zero, size: naturalSize).applying(transform)
        let displayW = abs(displayRect.width)
        let displayH = abs(displayRect.height)
        guard displayW > 1 && displayH > 1 else {
            throw ConvertError.noVideoTrack
        }
        let portrait = displayH >= displayW
        let outW = portrait ? 1080 : 1920
        let outH = portrait ? 1920 : 1080
        let outRect = CGRect(x: 0, y: 0, width: outW, height: outH)
        Diag.add("画面 \(Int(displayW))x\(Int(displayH)) → \(outW)x\(outH)")

        // 源文件有没有音轨（后面每遍读取都重新确认）
        let hasAudio = !asset.tracks(withMediaType: .audio).isEmpty

        // ---- 写入器 ----
        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("dayan_out_\(UUID().uuidString).mp4")
        try? FileManager.default.removeItem(at: outURL)
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
        if hasAudio {
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
        Diag.add("写入器已启动，音轨=" + (audioInput == nil ? "无" : "有"))

        // ---- 状态：帧号贯穿所有遍数，保证时间轴连续 ----
        var frameIndex = 0
        var audioAppendedSeconds = 0.0
        var wroteAnyFrame = false
        var lastReport = Date.distantPast
        var passNo = 0

        /// 处理一帧：合成 → 按帧号写 pts → 追加
        func appendFrame(_ sample: CMSampleBuffer) throws {
            guard let imageBuffer = CMSampleBufferGetImageBuffer(sample) else {
                frameIndex += 1
                return
            }
            guard let pool = adaptor.pixelBufferPool else {
                throw ConvertError.poolUnavailable
            }
            var outBuffer: CVPixelBuffer?
            _ = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &outBuffer)
            guard let ob = outBuffer else {
                throw ConvertError.poolUnavailable
            }
            self.render(source: imageBuffer,
                        destination: ob,
                        displaySize: CGSize(width: displayW, height: displayH),
                        transform: transform,
                        outW: outW,
                        outH: outH,
                        outRect: outRect)
            let pts = CMTime(seconds: Double(frameIndex) / fps, preferredTimescale: 600)
            if adaptor.append(ob, withPresentationTime: pts) {
                wroteAnyFrame = true
            }
            frameIndex += 1

            let now = Date()
            if now.timeIntervalSince(lastReport) > 0.2 {
                lastReport = now
                let p = min(1.0, Double(frameIndex) / Double(targetFrames))
                DispatchQueue.main.async { progress(p) }
            }
        }

        /// 读一遍源文件写到写入器里。返回这一遍（含断点续读）共写了多少帧。
        ///
        /// 关键：每次调用都新建 AVURLAsset 和 AVAssetReader，绝不复用旧的。
        /// 系统解码服务崩过一次（-11819）之后，旧 asset 上的轨道对象就废了，
        /// 拿来重试会立刻再报错，必须整套换新。
        /// 如果这一遍之前已经写了一部分帧（中途失败过），就从断点秒数续读：
        /// reader.timeRange 直接从断点开始，视频帧号和音轨时间轴都接着排，不用重头再来。
        func onePass(audioOffset: CMTime, passStartFrame: Int) throws -> Int {
            let startFrame = frameIndex

            // 断点取两条轨道里写得更靠前的那个：
            // 视频按已写帧数换算，音频按已追加的秒数换算。
            // 音频编码快，常常跑到视频前面几秒；只按视频帧算断点的话，
            // 续读出来的音频时间戳会倒退，会把写入器直接弄死。
            let videoResume = Double(startFrame - passStartFrame) / fps
            let audioResume = audioAppendedSeconds - Double(passNo - 1) * seconds
            var resumeSeconds = max(videoResume, audioResume)
            if resumeSeconds < 0 { resumeSeconds = 0 }
            if resumeSeconds >= seconds - 0.1 {
                return 0   // 这一遍其实已经写完了，不用再读
            }

            let freshAsset = AVURLAsset(url: source)
            guard let freshVideoTrack = freshAsset.tracks(withMediaType: .video).first else {
                throw ConvertError.noVideoTrack
            }

            let reader = try AVAssetReader(asset: freshAsset)
            let start = CMTime(seconds: resumeSeconds, preferredTimescale: 600)
            reader.timeRange = CMTimeRange(
                start: start,
                duration: CMTimeSubtract(freshAsset.duration, start)
            )
            if resumeSeconds > 0.05 {
                Diag.add("从第 \(String(format: "%.1f", resumeSeconds)) 秒断点续读（已写 \(startFrame - passStartFrame) 帧）")
            }

            let vOut = AVAssetReaderTrackOutput(
                track: freshVideoTrack,
                outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            )
            guard reader.canAdd(vOut) else {
                throw ConvertError.readerFailed("无法挂载视频输出")
            }
            reader.add(vOut)

            var aOut: AVAssetReaderTrackOutput?
            if audioInput != nil,
               let freshAudioTrack = freshAsset.tracks(withMediaType: .audio).first {
                let ao = AVAssetReaderTrackOutput(
                    track: freshAudioTrack,
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
                throw ConvertError.readerFailed(self.explain(reader.error, fallback: "启动读取失败"))
            }

            var videoDone = false
            var audioDone = (aOut == nil)
            var idle = 0

            while (!videoDone || !audioDone) && frameIndex < targetFrames {
                var didSomething = false

                if !videoDone && videoInput.isReadyForMoreMediaData {
                    if let sample = vOut.copyNextSampleBuffer() {
                        didSomething = true
                        try appendFrame(sample)
                    } else {
                        videoDone = true
                    }
                }

                if !audioDone, let ao = aOut, let ai = audioInput, ai.isReadyForMoreMediaData {
                    if let sample = ao.copyNextSampleBuffer() {
                        didSomething = true
                        // 注意：offset 只按遍数算，不含断点秒数——
                        // 续读出来的音轨自带原始时间戳（从断点秒数起），
                        // 再加上断点就重复了
                        if let shifted = self.retime(sample, by: audioOffset) {
                            if ai.append(shifted) {
                                audioAppendedSeconds += self.bufferSeconds(sample)
                            } else {
                                audioDone = true
                            }
                        }
                    } else {
                        audioDone = true
                    }
                }

                if reader.status == .failed {
                    throw ConvertError.readerFailed(self.explain(reader.error, fallback: "读取中断"))
                }
                if writer.status == .failed {
                    throw ConvertError.writerFailed(self.explain(writer.error, fallback: "写入中断"))
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
            return frameIndex - startFrame
        }

        // ---- 主循环：一遍一遍地读，直到凑够目标帧数 ----
        // 读取失败（解码服务崩了）就等它恢复、换一套全新解码器从断点续读，最多救 3 次。
        // 写入器的错救不了（文件已经写坏），直接抛出。
        while passNo < loops && frameIndex < targetFrames {
            passNo += 1
            let passStartFrame = frameIndex
            let offset = CMTime(seconds: Double(passNo - 1) * seconds, preferredTimescale: 600)

            var written = -1
            var attempt = 0
            while written < 0 {
                attempt += 1
                do {
                    written = try autoreleasepool {
                        try onePass(audioOffset: offset, passStartFrame: passStartFrame)
                    }
                } catch let e as ConvertError {
                    guard case .readerFailed = e else { throw e }
                    if attempt >= 4 {
                        Diag.add("换了 \(attempt) 套解码器都失败，放弃")
                        throw e
                    }
                    let waitSec = Double(attempt) * 1.5
                    Diag.add("已写好 \(frameIndex) 帧不丢，等 \(String(format: "%.1f", waitSec)) 秒让系统解码服务恢复，换全新解码器续读")
                    Thread.sleep(forTimeInterval: waitSec)
                }
            }
            Diag.add("第 \(passNo) 遍完成，本遍 \(written) 帧，累计 \(frameIndex) 帧")
        }

        videoInput.markAsFinished()
        audioInput?.markAsFinished()

        guard wroteAnyFrame else {
            writer.cancelWriting()
            throw ConvertError.unknown("一帧都没有处理成功，可能是画面尺寸异常")
        }

        Diag.add("共 \(frameIndex) 帧，开始收尾")
        let sem = DispatchSemaphore(value: 0)
        writer.finishWriting { sem.signal() }
        sem.wait()

        guard writer.status == .completed else {
            throw ConvertError.writerFailed(explain(writer.error, fallback: "收尾失败"))
        }

        DispatchQueue.main.async { progress(1.0) }
        return outURL
    }

    // MARK: - 音轨时间轴偏移

    /// 一段音频采样缓冲的时长（秒），用于统计音轨写到了哪
    private func bufferSeconds(_ sample: CMSampleBuffer) -> Double {
        var dur = CMSampleBufferGetDuration(sample)
        if !dur.isValid || dur.seconds <= 0 {
            let n = max(1, CMSampleBufferGetNumSamples(sample))
            dur = CMTime(value: CMTimeValue(n), timescale: 44100)
        }
        return dur.seconds
    }


    /// 第 N 遍的音轨整体往后挪 (N-1)×段长，保证多个遍数接起来时间轴是连续的。
    private func retime(_ sample: CMSampleBuffer, by offset: CMTime) -> CMSampleBuffer? {
        if offset == .zero {
            return sample
        }
        var dur = CMSampleBufferGetDuration(sample)
        if !dur.isValid || dur.seconds <= 0 {
            let n = max(1, CMSampleBufferGetNumSamples(sample))
            dur = CMTime(value: CMTimeValue(n), timescale: 44100)
        }
        var timing = CMSampleTimingInfo(
            duration: dur,
            presentationTimeStamp: CMTimeAdd(CMSampleBufferGetPresentationTimeStamp(sample), offset),
            decodeTimeStamp: .invalid
        )
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
            s += "：系统解码服务崩了，重启解码器可以救"
        }
        return s
    }

    // MARK: - 单帧合成

    private func render(source: CVPixelBuffer,
                        destination: CVPixelBuffer,
                        displaySize: CGSize,
                        transform: CGAffineTransform,
                        outW: Int,
                        outH: Int,
                        outRect: CGRect) {
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
