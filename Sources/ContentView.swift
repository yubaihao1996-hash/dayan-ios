import SwiftUI
import PhotosUI
import Photos
import AVFoundation
import UniformTypeIdentifiers
import CoreTransferable

struct PickedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let ext = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent("pick_\(UUID().uuidString).\(ext)")
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.copyItem(at: received.file, to: dest)
            return PickedMovie(url: dest)
        }
    }
}

struct ContentView: View {

    @State private var selectedItem: PhotosPickerItem?
    @State private var sourceURL: URL?
    @State private var sourceInfo = "还没有选视频"
    @State private var status = ""
    @State private var progress: Double = 0
    @State private var busy = false
    @State private var alertMessage = ""
    @State private var showAlert = false

    private let converter = VideoConverter()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {

            VStack(alignment: .leading, spacing: 6) {
                Text("大眼视频转换")
                    .font(.title2).bold()
                Text("竖版出 1080×1920，横版出 1920×1080。\n比例不对的用模糊背景补边，不拉伸不裁切。")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }

            PhotosPicker(selection: $selectedItem, matching: .videos) {
                HStack {
                    Image(systemName: "film")
                    Text("选择视频")
                }
                .font(.body)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Color.blue.opacity(0.12))
                .cornerRadius(10)
            }
            .disabled(busy)
            .onChange(of: selectedItem) { _ in
                handlePickedItem()
            }

            Text(sourceInfo)
                .font(.footnote)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(3)

            if busy {
                ProgressView(value: progress)
                Text(status).font(.footnote).foregroundColor(.secondary)
            } else {
                Text(status).font(.footnote).foregroundColor(.secondary)
            }

            Button {
                startConvert()
            } label: {
                Text("开始转换")
                    .font(.body)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background((sourceURL == nil || busy) ? Color.gray.opacity(0.25) : Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(10)
            }
            .disabled(sourceURL == nil || busy)

            Spacer()

            Text("版本 " + (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"))
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(20)
        .alert("提示", isPresented: $showAlert) {
            Button("知道了", role: .cancel) { }
        } message: {
            Text(alertMessage)
        }
    }

    // MARK: - 选择视频

    private func handlePickedItem() {
        guard let item = selectedItem else { return }
        busy = true
        progress = 0
        status = "正在读取视频…"

        Task {
            do {
                guard let movie = try await item.loadTransferable(type: PickedMovie.self) else {
                    throw ConvertError.unknown("读不到这个视频，换一个试试")
                }
                let info = ContentView.describe(url: movie.url)
                await MainActor.run {
                    sourceURL = movie.url
                    sourceInfo = info
                    status = ""
                    busy = false
                }
            } catch {
                await MainActor.run {
                    busy = false
                    status = ""
                    alertMessage = error.localizedDescription
                    showAlert = true
                }
            }
        }
    }

    private static func describe(url: URL) -> String {
        let name = url.lastPathComponent
        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .video).first else {
            return name + "\n读不到视频轨道"
        }
        let rect = CGRect(origin: .zero, size: track.naturalSize)
            .applying(track.preferredTransform)
        let w = Int(abs(rect.width))
        let h = Int(abs(rect.height))
        let portrait = h >= w
        let secs = CMTimeGetSeconds(asset.duration)
        let dur = secs.isFinite ? String(format: "%.1f", secs) : "?"
        let fps = Int(track.nominalFrameRate.rounded())
        var line = name + "\n" + "\(w)×\(h) " + (portrait ? "竖版" : "横版")
            + " · \(dur) 秒 · \(fps) 帧"
        if secs.isFinite && secs < 59.5 {
            let loops = max(2, Int(ceil((60.0 - 0.5) / secs)))
            let final = min(Double(loops) * secs, 60.0)
            line += "\n将循环 \(loops) 次补到 \(String(format: "%.0f", final)) 秒"
        }
        return line
    }

    // MARK: - 转换

    private func startConvert() {
        guard let url = sourceURL else { return }
        busy = true
        progress = 0
        status = "正在准备（拼接循环）…"

        converter.convert(source: url, progress: { p in
            progress = p
            if p > 0 {
                status = "正在转换 " + String(Int(p * 100)) + "%"
            }
        }, completion: { result in
            busy = false
            switch result {
            case .success(let out):
                status = "转换完成，正在存相册…"
                saveToAlbum(url: out)
            case .failure(let err):
                status = "转换失败"
                alertMessage = err.localizedDescription
                showAlert = true
            }
        })
    }

    private func saveToAlbum(url: URL) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { state in
            guard state == .authorized || state == .limited else {
                DispatchQueue.main.async {
                    status = "没有相册写入权限"
                    alertMessage = "请在系统设置里允许本 App 访问相册，然后再转一次"
                    showAlert = true
                }
                return
            }
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            }, completionHandler: { ok, err in
                DispatchQueue.main.async {
                    if ok {
                        status = "已保存到相册"
                    } else {
                        status = "保存失败"
                        alertMessage = err?.localizedDescription ?? "存相册失败"
                        showAlert = true
                    }
                }
            })
        }
    }
}
