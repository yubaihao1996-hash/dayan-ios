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

/// 把一条视频转成标准尺寸：竖版 1080x1920、横版 1920x1080。
/// 非标准比例不拉伸不裁切，用同画面的模糊放大版做背景补边。
/// 这一版先不做循环补时长，输出保持源视频的原始长度。
final class VideoConverter {

    /// 如果真机上发现画面上下颠倒，把这里改成 true（只影响竖直方向，不影响左右）
    private static let verticalFlip = false

    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private let queue = DispatchQueue(label: "com.bh.dayan.convert", qos: .userInitiated)

    func convert(source: URL,
                 progress: @escaping (Double) -> Void,
                 completion: @escaping (Result<URL, Error>) -> Void) {
        queue.async {
            do {
                let out = try self.run(source: source, progress: progress)
                DispatchQueue.main.async { completion(.success(out)) }
            } catch {
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

        let naturalSize = videoTrack.naturalSize
        let transform = videoTrack.preferredTransform

        // 应用方向变换后的显示尺寸，用来判断横竖
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

        var fps = Double(videoTrack.nominalFrameRate)
        if fps < 20 || fps > 61 { fps = 30 }
        fps = fps.rounded()

        let seconds = CMTimeGetSeconds(asset.duration)
        guard seconds.isFinite && seconds > 0 else {
            throw ConvertError.unknown("读不到视频时长")
        }
        let totalFrames = max(1, Int((seconds * fps).rounded()))
        let fpsInt = Int(fps)

        // ---- 读取器 ----
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: .zero, duration: asset.duration)

        let videoOutput = AVAssetReaderTrackOutput(
            track: videoTrack,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        )
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else {
            throw ConvertError.readerFailed("无法挂载视频输出")
        }
        reader.add(videoOutput)

        var audioOutput: AVAssetReaderTrackOutput?
        if let audioTrack = asset.tracks(withMediaType: .audio).first {
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
                audioOutput = ao
            }
        }

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
                AVVideoMaxKeyFrameIntervalKey: fpsInt * 2,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoExpectedSourceFrameRateKey: fpsInt
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
        if audioOutput != nil {
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
            throw ConvertError.writerFailed(writer.error?.localizedDescription ?? "启动写入失败")
        }
        writer.startSession(atSourceTime: .zero)

        guard reader.startReading() else {
            writer.cancelWriting()
            throw ConvertError.readerFailed(reader.error?.localizedDescription ?? "启动读取失败")
        }

        // ---- 逐帧处理 ----
        var frameIndex = 0
        var wroteAnyFrame = false
        var videoFinished = false
        var audioFinished = (audioInput == nil)
        var lastReport = Date.distantPast
        var idleRounds = 0

        while !videoFinished || !audioFinished {
            var didSomething = false

            if !videoFinished && videoInput.isReadyForMoreMediaData {
                if let sample = videoOutput.copyNextSampleBuffer() {
                    didSomething = true
                    if let imageBuffer = CMSampleBufferGetImageBuffer(sample) {
                        if let pool = adaptor.pixelBufferPool {
                            var outBuffer: CVPixelBuffer?
                            _ = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &outBuffer)
                            if let ob = outBuffer {
                                render(source: imageBuffer,
                                       destination: ob,
                                       displaySize: CGSize(width: displayW, height: displayH),
                                       transform: transform,
                                       outW: outW,
                                       outH: outH,
                                       outRect: outRect)
                                let pts = CMTime(seconds: Double(frameIndex) / fps,
                                                 preferredTimescale: 600)
                                if adaptor.append(ob, withPresentationTime: pts) {
                                    wroteAnyFrame = true
                                }
                            }
                        }
                    }
                    frameIndex += 1

                    let now = Date()
                    if now.timeIntervalSince(lastReport) > 0.2 {
                        lastReport = now
                        let p = min(1.0, Double(frameIndex) / Double(totalFrames))
                        DispatchQueue.main.async { progress(p) }
                    }
                } else {
                    videoInput.markAsFinished()
                    videoFinished = true
                }
            }

            if !audioFinished, let ai = audioInput, let ao = audioOutput {
                if ai.isReadyForMoreMediaData {
                    if let sample = ao.copyNextSampleBuffer() {
                        didSomething = true
                        ai.append(sample)
                    } else {
                        ai.markAsFinished()
                        audioFinished = true
                    }
                }
            }

            if reader.status == .failed {
                writer.cancelWriting()
                throw ConvertError.readerFailed(reader.error?.localizedDescription ?? "读取中断")
            }
            if writer.status == .failed {
                throw ConvertError.writerFailed(writer.error?.localizedDescription ?? "写入中断")
            }

            if !didSomething {
                idleRounds += 1
                if idleRounds > 3000 {
                    writer.cancelWriting()
                    throw ConvertError.writerFailed("编码器长时间不接受数据，可能是这个尺寸不被支持")
                }
                Thread.sleep(forTimeInterval: 0.005)
            } else {
                idleRounds = 0
            }
        }

        guard wroteAnyFrame else {
            writer.cancelWriting()
            throw ConvertError.unknown("一帧都没有处理成功，可能是画面尺寸异常")
        }

        let sem = DispatchSemaphore(value: 0)
        writer.finishWriting { sem.signal() }
        sem.wait()

        guard writer.status == .completed else {
            throw ConvertError.writerFailed(writer.error?.localizedDescription ?? "收尾失败")
        }

        DispatchQueue.main.async { progress(1.0) }
        return outURL
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
