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
        let s = lines.suffix(26).joined(separator: "\n")
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
/// 帧号接着往下排、音轨时间轴按段偏移。这样读取的永远是一个普通视频文件，
/// 避开了 AVAssetReader 读合成对象时报 -11800 / -11819 的问题。
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

        // 源文件有音轨才建音频输入
        let hasAudio = !asset.tracks(withMediaType: .audio).isEmpty
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

        /// 读一遍源文件，写到写入器里。返回这一遍写了多少帧。
        func onePass(audioOffset: CMTime) throws -> Int {
            let startFrame = frameIndex

            let reader = try AVAssetReader(asset: asset)
            reader.timeRange = CMTimeRange(start: .zero, duration: asset.duration)

            let vOut = AVAssetReaderTrackOutput(
                track: videoTrack,
                outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            )
            vOut.alwaysCopiesSampleData = false
            guard reader.canAdd(vOut) else {
                throw ConvertError.readerFailed("无法挂载视频输出")
            }
            reader.add(vOut)

            var aOut: AVAssetReaderTrackOutput?
            if audioInput != nil,
               let audioTrack = asset.tracks(withMediaType: .audio).first {
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
                ao.alwaysCopiesSampleData = false
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
                        if let shifted = self.retime(sample, by: audioOffset) {
                            if !ai.append(shifted) {
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
        while passNo < loops && frameIndex < targetFrames {
            passNo += 1
            let offset = CMTime(seconds: Double(passNo - 1) * seconds, preferredTimescale: 600)

            var attempt = 0
            var written = -1
            while written < 0 {
                attempt += 1
                do {
                    written = try autoreleasepool { try onePass(audioOffset: offset) }
                } catch {
                    Diag.add("第 \(passNo) 遍失败：" + error.localizedDescription)
                    if attempt >= 2 { throw error }
                    Diag.add("0.8 秒后重试一次")
                    Thread.sleep(forTimeInterval: 0.8)
                }
            }
            Diag.add("第 \(passNo) 遍完成，本遍 \(written) 帧，累计 \(frameIndex) 帧")
            if written == 0 { break }
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

    /// 第 N 遍的音轨整体往后挪 N×段长，保证多个遍数接起来时间轴是连续的。
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
            s += "（底层 \(under.domain) \(under.code)）"
        } else if ns.domain == "AVFoundationErrorDomain" {
            s += "（\(ns.code)）"
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
