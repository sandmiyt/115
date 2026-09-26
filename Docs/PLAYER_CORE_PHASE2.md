# 第 2 阶段：FFmpeg 8.0.2 依赖接入与已缓冲区域拖动修复

版本：2.2.9（43）。以已完成接口迁移的 42 号构建为基础；用户已同意进入此阶段。

## 实际实现

- 从官方 `https://ffmpeg.org/releases/ffmpeg-8.0.2.tar.xz` 构建，SHA-256 固定为 `5d16962332603c427b3d0887fc12b9166d6ee2cb1108b1865dd2d5eb06a09505`。
- `Dependencies/FFmpeg/build-apple.sh` 编译 iOS arm64 和 iOS Simulator arm64 两个动态 Framework，再组合 XCFramework。
- 编译 libavformat、libavcodec、libavutil、libswresample、libswscale，启用 VideoToolbox / AudioToolbox / SecureTransport。禁用 GPL、nonfree、version3、编码器、封装器和自动探测外部库。
- 只导出 `CinevaFFmpeg*` 前缀的 C 桥接口，链接时隐藏 FFmpeg 内部符号，并检查实际导出表，避免与 MobileVLCKit 的 FFmpeg ABI 混用。
- 本地 CocoaPod 引入真实 XCFramework。`PlayerCore/FFmpegRuntime.swift` 是唯一直接导入 C 模块的 Swift 文件，UI 不接触 libav 类型。
- 设置 → 关于 → FFmpeg 集成信息：实际库版本、实际编译进库的解码器/解封装器/VideoToolbox 配置、真实对象分配释放检查和 LGPL 许可。
- 对象检查调用 libavformat / libavcodec / libavutil / libswresample / libswscale 的真实函数；它不打开网络、不创建硬件会话，**不是播放测试**。
- LGPL 许可、对应的未修改完整源码压缩包、配置和桥接源码随动态框架打包。构建脚本也包含在包内，支持复现。最终 App Store 分发义务仍需按具体分发方式核验。

## 已缓冲区域拖动

问题：旧逻辑松手后直接把 seek 标记为加载中；即使目标处于 `loadedTimeRanges` 内也会走同一个 350 ms 提示，且 ±100 ms 的严格落点会要求更多 GOP 解码。

- 松手时读取当前 AVPlayerItem 的真实 loadedTimeRanges，不使用已下载字节数推算。
- 在已加载区间内部，允许最多 ±0.5 秒的落点容差；容差被限制在该区间内。未缓冲目标保留原先 ±0.1 秒的容差。
- 对这种已缓冲定位给予 900 ms 的提示宽限；完成更快时不闪圈。未缓冲等待仍为 350 ms，持续等待仍显示加载，不无限隐藏。
- `PlayerLoadingFeedback` 带操作代次，新拖动或完成后旧的延迟提示会失效。
- 仅在用户这一次 seek 成功完成、播放器 ready、缓冲不为空、落点仍有至少两秒（按倍速增加）的新鲜连续数据时，调用一次立即恢复。普通播放缓冲恢复策略不变。
- 继续沿用已有 generation/item 身份检查；暂停时拖动不会自动开始播放。

已加载数据不等于目标帧/前置关键帧已解码。这是针对提示和恢复路径的修复，不承诺所有文件任意位置毫秒跳转，也不是自定义 Range 缓存。

## 阶段边界

本阶段集成的是实际 FFmpeg 库，**实际视频播放仍由 AVPlayer / VLC 负责**。没有把它们冒充 FFmpegPlayer，也没有用元数据探测声称已完成解码内核。

下阶段才接入 FFmpeg 解封装与解码播放。硬解会话、独立音频时钟、自定义 AVIO、缓存队列、libass/PGS、FFmpeg HDR 渲染和自定义 PiP 尚未完成。

编译发现的 VideoToolbox 配置只说明代码已进入库，不能证明此 iPhone 支持某个 profile/pixel format。真实硬解能力与软件 fallback 必须在后续阶段逐一验收。

## 文件清单

- `Dependencies/FFmpeg/Bridge/CinevaFFmpeg.{h,c}`
- `Dependencies/FFmpeg/build-apple.sh`、`CinevaFFmpeg.podspec`、`COPYING.LGPLv2.1`
- `Gallery115/PlayerCore/FFmpegRuntime.swift`、`PlayerEngine.swift`、`PlayerTypes.swift`
- `Gallery115/Player/PlayerModel.swift`
- `Gallery115/Views/PlayerScreen.swift`、`SettingsView.swift`
- `Gallery115.xcodeproj/project.pbxproj`、`Podfile`、`.gitignore`
- 原有 IPA 工作流增加依赖编译及缓存步骤；没有新增 regression 工作流或测试产物。

## 验证与设备验收

- 本地源码预检与 Bash 语法检查；真实 Apple 编译由 GitHub macOS 工作流执行，具体结果以交付消息和对应提交为准。
- 新库的符号隔离与 LGPL 配置在构建中强制检查，任一失败阻止产物生成。
- 本地 Windows 无 Xcode，真机未验证；依赖对象检查须在 iPhone 打开“FFmpeg 集成信息”触发。
- 安装后检查版本为 8.0.2、对象检查通过、能返回设置并正常播放；特别检查同时打开过 FFmpeg 信息页和 VLC 后是否闪退。
- 同一原画视频测试：已缓冲区内连续拖动十次、区间边缘、未缓冲区域、暂停时拖动、1x/2x、拖动后立即退出、切换下一集。
- 短暂已缓冲 seek 不应闪圈；真正长时间等待仍应显示加载；不应在松手后跳回旧位置或意外开始播放。
- 检查 AVPlayer/VLC 原有播放、PiP、后台音频、字幕和历史。设备验收通过后再进入第 3 阶段。

参考：[FFmpeg 官方源码](https://ffmpeg.org/releases/)、[FFmpeg 许可说明](https://ffmpeg.org/legal.html)、[Apple seek 合并建议](https://developer.apple.com/library/archive/qa/qa1820/_index.html)。
