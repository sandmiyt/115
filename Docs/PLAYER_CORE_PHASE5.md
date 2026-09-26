# 第 5 阶段：独立原生视频渲染

版本 2.2.9（46）。用户确认第 4 阶段其他解码视频正常，但一条 HDR 视频有画面后持续缓冲。没有该视频或真机日志，不能把代码中发现的显示等待风险等同于已确认的唯一故障原因。

## 实现

沿用现有 VideoSource → FFmpeg 8.0.2 HTTP / demux → 有界队列 → VideoToolbox / 软件解码 → CVPixelBuffer，新增独立 `NativeVideoRenderer` → `AVSampleBufferVideoRenderer` / `AVSampleBufferDisplayLayer`。本阶段选择需求允许的 Apple Native 路线；没有新增 Metal shader，也没有通过 AVPlayer 播放此验证入口。

- 硬解 CVPixelBuffer 直接交给原生输出，不转换 UIImage/CGImage，不做应用侧 RGB 拷贝。NV12/P010、色彩附件、HDR10/HLG 标记仍保留；HDR 屏幕亮度/色准未在 Windows 上验证。
- 渲染器拥有 host-clock timebase。CADisplayLink 仅有限预送帧（每次最多 8 帧、最多提前 150 ms），显示由原生时间戳调度。后续音频主时钟在第 6 阶段实现。
- 缓冲恢复先恢复时钟，再检查显示层 readiness，避免暂停时钟与显示队列互等。持续阻塞超过 1.5 秒且不属于正常预送时，flush 并重新锚定；每次会话最多恢复两次，失败给出错误而不是无限重试。
- 首帧、seek 首帧和恢复首帧设置 DisplayImmediately；普通连续帧仍按 PTS 显示。seek 清除旧图像和代次，缓冲保留现有画面。
- 采样带明确帧时长；格式描述仅在匹配像素缓冲格式及附件时复用，改变时重新生成；重复/倒退及严重迟到帧丢弃并计数。
- 消费帧之后重新读取原生队列快照，避免根据旧队列数量误判缓冲或结束。
- 验证页显示解码计数、显示入队计数、迟到丢帧、恢复次数、时钟/当前/下一帧 PTS，以及数据/解码/显示等待位置。支持复制诊断；不包含 URL、请求头、Cookie。

原来的 FFmpeg 构建、硬解 codec 范围及软件回退沿用第 4 阶段。115 仍使用 FFmpeg 内建 HTTP IO，应用自定义 AVIO、Range 缓存仍待第 7/8 阶段；没有在本阶段声称实现重复 Range 去重或毫秒 seek。

## 文件

- `Gallery115/PlayerCore/NativeVideoRenderer.swift`：新渲染器、时钟、格式复用及阻塞恢复。
- `Gallery115/PlayerCore/FFmpegDecodeSession.swift`：解码与显示分离、帧交付及诊断。
- `Gallery115/Player/FFmpegDecodeValidationView.swift`：诊断显示/复制。
- `Gallery115/Views/SettingsView.swift`、`Gallery115.xcodeproj/project.pbxproj`：阶段说明、源文件注册及构建号。

## 验证与未完成范围

本地现有 `Tests/preflight.py` 与 diff 检查通过；脚本没有执行 XCTest。实际 Swift 类型检查/链接/IPA 打包由 GitHub macOS 完成，以对应提交的构建结果为准。未新增 regression 作业、脚本或产物。Windows 不能执行 iPhone HDR、流畅度或能耗验证。

入口仍为「播放详情 → FFmpeg 解码验证（无声）」。音频输出/AV Sync、字幕、完整 Dolby、FFmpeg PiP/AirPlay、默认内核替换未在本阶段完成；普通播放器沿用原路径。

真机检查：

1. 同一条 HDR 视频保持优先硬解，观察能否连续播放、时间与解码/显示帧是否持续增长；核对 10 位和 PQ/HLG 信息。
2. 暂停后拖动、播放中拖动、前后跳 10 秒、软硬解切换，检查目标帧与继续播放；再用已正常的 SDR 视频对照。
3. 若 HDR 仍卡住，复制诊断，特别检查“已有压缩数据/已有解码帧”、下一帧 PTS、硬解方式与恢复次数。软件对照仅作定位，不能以其可播替代硬解验收。
4. 退出、锁屏、重入与正常播放器检查无闪退及旧画面回流。

参考：

- [Apple 原生采样输出与时间戳/DisplayImmediately 规则](https://developer.apple.com/documentation/avfoundation/avsamplebufferdisplaylayer/enqueue(_:))
- [Apple 显示失败与 flush 恢复](https://developer.apple.com/documentation/avfoundation/avsamplebuffervideorenderer/status)
- [Apple 视频格式与像素缓冲匹配](https://developer.apple.com/documentation/coremedia/cmvideoformatdescriptionmatchesimagebuffer(_:imagebuffer:))
