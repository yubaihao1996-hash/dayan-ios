# 大眼视频转换 · iOS 版

把视频转成标准尺寸的小工具。竖版出 **1080×1920**，横版出 **1920×1080**；
比例不标准的视频不拉伸不裁切，用同一画面的模糊放大版当背景补边。

## 怎么编译

这个仓库不包含 `.xcodeproj`，由 XcodeGen 按 `project.yml` 现生成，
所以换机器不用改任何工程文件。

推送到仓库后，GitHub Actions 会在云端 macOS 机器上自动执行：

```
brew install xcodegen            # 装工程生成器
xcodegen generate                # 生成 DaYan.xcodeproj
xcodebuild ... CODE_SIGNING_ALLOWED=NO   # 不做签名编译
zip -qry DaYan.ipa Payload       # 打包成 ipa
```

产物在 Actions 运行页底部的 **Artifacts → DaYan-ipa** 里下载。
ipa 是未签名的，需要自己在本地用 Sideloadly 之类工具签名才能装进 iPhone。

本机有 Mac 的话：

```bash
brew install xcodegen
xcodegen generate
open DaYan.xcodeproj      # 之后正常用 Xcode 跑
```

## 文件说明

| 文件 | 作用 |
|---|---|
| `project.yml` | XcodeGen 工程描述：target、bundle id、Info.plist 键、编译设置 |
| `Sources/DaYanApp.swift` | App 入口，只有一个窗口 |
| `Sources/ContentView.swift` | 界面：选视频、显示参数、进度、存相册 |
| `Sources/VideoConverter.swift` | 核心：解码 → 模糊补边合成 → 硬件编码 → 落盘 |
| `.github/workflows/build.yml` | 云端编译流水线 |

## 技术要点

- **解码**：`AVAssetReader`，输出 BGRA 像素缓冲
- **方向**：按 `videoTrack.preferredTransform` 旋转，再按显示尺寸判断横竖
- **合成**：`CoreImage`。背景缩到 1/4 后做 `CIGaussianBlur`（半径 5，放大回去约等于原尺寸 20），
  前景按 `min(W/dw, H/dh)` 等比装入，居中叠在背景上
- **编码**：`AVAssetWriter` + H.264（VideoToolbox 硬编），12 Mbps，GOP 2 秒
- **音轨**：reader 出 PCM → writer 出 AAC 192k，与视频同步写
- **相册**：`PHAssetChangeRequest.creationRequestForAssetFromVideo`

## 当前版本的限制

这一版只跑单条视频，保持源片时长。批量、循环补到 60 秒、日志面板都还没加，
等真机验证通过后再补。

## 最低系统要求

iOS 16.0（`PhotosPicker` 需要）。

## 两个容易踩的点

1. **`UILaunchScreen` 必须是空字典**。Info.plist 里少了它，iOS 14 之后启动会异常。
2. **模糊要缩小后再做**。1080×1920 全尺寸直接高斯模糊非常慢，缩到 1/4、
   半径同比缩小、结果再放大，观感一样但快一个数量级。
