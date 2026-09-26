# 第 4 阶段：VideoToolbox 硬件解码与 HDR 像素输出

版本 2.2.9（45）。用户已确认第 3 阶段可正常出画面，并反馈 HDR 不支持，授权进入本阶段。

## 已实现

链路：现有 115 / WebDAV VideoSource → FFmpeg HTTP / 解封装 → 有界包队列 → VideoToolbox 硬解优先 / FFmpeg 软件回退 → CVPixelBuffer → 原生 AVSampleBufferDisplayLayer。音频目前仍只解码计数，无声验证入口没有成为日常默认内核。

### 硬解选择与失败回退

- 检查编译的 AVCodecHWConfig、Apple 设备 codec 能力，再创建 AV_HWDEVICE_TYPE_VIDEOTOOLBOX；get_format 实际选用 AV_PIX_FMT_VIDEOTOOLBOX。
- 选择范围为 H.264、HEVC（包括设备会话接受的 Main10）、VP9、AV1、MPEG-2、MPEG-4。支持取决于设备、profile、位深及色度格式，**没有在开发电脑上验证某款 iPhone 的 codec 能力**。
- FFmpeg 8.0.2 原版对 HEVC 使用 EnableHardware，会允许 VideoToolbox 内部软解。本版本附带有日期标识的最小补丁，所有候选都使用 RequireHardware。因此收到 VT 输出帧才标记硬解，不能把 API 支持列表等同于当前解码方式。
- 无硬解配置、设备不支持、设备创建失败或会话格式初始化被拒绝时选择软件解码；get_format 会跳过所有硬件格式。
- 硬解过程中失败时关闭硬件 codec，重建软件 codec，递增 serial、清队列、从当前播放点前的关键帧重新解码。若用户同时 seek，优先保留用户最新目标；不会从非关键帧直接喂给一个空的软件 decoder。每个会话最多降级一次，避免循环重试。
- 增加实际硬解/软解帧数、当前解码方式及回退原因。验证页的“优先硬件解码”开关可重新打开同一位置，进行软件对照，不修改默认画质或普通播放器设置。

### HDR10 / HLG 与像素输出

- 解除原先所有 PQ/HLG 一律拒绝的限制。硬解直接 retain FFmpeg frame.data[3] 的 CVPixelBuffer，保持原分辨率及 NV12/P010 等原生格式，应用不锁定像素地址、不调用 swscale、不逐帧复制为 BGRA/UIImage。
- 软件回退仍限制显示到 1280×720，但改用 NV12 / P010；10 位或 PQ/HLG 内容保留至少 10 位输出，不先压成 8 位 SDR。
- 传递真实 primaries、PQ/HLG transfer、YCbCr matrix 和范围；将 FFmpeg 的 mastering display、MaxCLL/MaxFALL 转为 CoreVideo 对应的大端数据附件。缺少元数据不填假值。硬解现有未知附件保留。
- 显示真实输出分辨率、位深、色彩字段及 MDCV/CLL 附件存在状态。AVPlayer.eligibleForHDRPlayback 仅报告设备资格，**不代表当前屏幕实际亮度或 HDR 色准已测量**。
- Dolby Vision 流的动态元数据路线尚未完成；检测到 DOVI 配置时明确提示返回原系统播放器。原 AVPlayer Dolby/PiP 路线仍保留；本入口不冒称 Dolby Vision 或 Atmos 支持。
- 原生显示层负责最终颜色呈现。未实现应用自有 Tone Mapping、Metal 色彩管线、HDR10+ 或 Dolby 动态元数据重建。HDR10/HLG 的真实高光、暗部和颜色仍需 iPhone 验收。

### 内存与交互

- 压缩队列继续受包数、16 MiB 及累计时长限制；超过 1080p 的输出队列最多 3 帧，其余最多 6 帧。显示预送限制为约两帧且不超过 120 ms，减少 4K P010 缓冲占用。这不包含系统 decoder 内部参考帧，不能声称总内存为队列大小。
- 保留原有 seek serial、取消、后台停止和后台 join；内部软件恢复也会让 Swift 清除旧显示队列，避免恢复后旧硬解帧闪回。
- 主播放器、登录、资料库、字幕、历史、PiP 和后台播放继续沿用原路径。

## FFmpeg 构建与许可

仍固定官方 8.0.2 原始压缩包及 SHA256。构建前应用 `Patches/require-hardware.patch`，缓存键包含补丁。上游源码、补丁、配置、桥接源码、构建脚本和 LGPL 文本随动态 framework 分发。内部 libav 符号仍隐藏，避免与 VLC 混用 ABI；没有启用 GPL/nonfree。

## 主要修改文件

- `Dependencies/FFmpeg/Bridge/CinevaFFmpegSession.c`：设备/格式选择、回退与关键帧恢复。
- `Dependencies/FFmpeg/Bridge/CinevaVideoOutput.{h,c}`：CVPixelBuffer 原生转交、软件 NV12/P010、HDR 元数据。
- `Dependencies/FFmpeg/Bridge/CinevaFFmpeg.h`：诊断 ABI、硬解偏好和播放时钟反馈。
- `Dependencies/FFmpeg/Patches/require-hardware.patch`、`build-apple.sh`、`CinevaFFmpeg.podspec`：可复现依赖构建与源码交付。
- 原 IPA workflow：依赖缓存键加入补丁；无新增 regression 作业/脚本/产物。
- `Gallery115/PlayerCore/FFmpegDecodeSession.swift`：恢复代次、实际硬解/HDR 诊断及显示预送上限。
- `Gallery115/Player/FFmpegDecodeValidationView.swift`：硬解/软件对照和 HDR 验证信息。
- `Gallery115/Views/SettingsView.swift`、Xcode project：阶段说明与版本 45。

## 未完成与验证范围

未实现音频输出/音频主时钟、自定义 AVIO、应用级 Range 缓存、完整字幕、Dolby、FFmpeg PiP/AirPlay、最终 Metal/色彩管理及设备性能验收。不能据此声称所有长视频已不卡顿、毫秒 seek、全格式硬解或零拷贝整个系统链路。

本地运行现有源码 preflight、Bash 语法、diff、补丁对固定源码的适用性检查。实际 Apple 编译/IPA 由 GitHub macOS 执行，结果以交付消息和对应 commit 的运行记录为准。Windows 未执行模拟器、真机硬解或 HDR 色准测试。

## iPhone 验收

1. 普通播放仍正常；进入「播放详情 → FFmpeg 解码验证（无声）」。
2. 用同一 H.264 和 HEVC SDR 长视频检查是否显示 VideoToolbox 硬件解码、硬解帧数增长，记录首帧和定位耗时。
3. 用 HEVC Main10 HDR10 / HLG 文件检查原分辨率、10 位、PQ/HLG 信息；观察高光、暗部、肤色和亮度是否正常。元数据没有的文件显示“无”是允许的。
4. 关闭“优先硬件解码”确认实际软解帧数增长，HDR 文件依然显示 10 位；再打开检查恢复硬解。此开关验证软件路径，不等于已经实测所有硬件故障回退。
5. 暂停和播放状态分别反复 seek、切换软硬解、退出重入及锁屏，确认无旧帧、闪退和退出后持续占用。
6. Dolby Vision 文件应提示使用原播放器，不应显示一张严重偏色画面并自称 Dolby 支持。

参考：[FFmpeg 官方硬解接口示例](https://ffmpeg.org/doxygen/8.0/hw_decode_8c-example.html)、[Apple HDR 显示与 10 位像素说明](https://developer.apple.com/av-foundation/Incorporating-HDR-video-with-Dolby-Vision-into-your-apps.pdf)。实际 VT 选择和 RequireHardware 补丁依据本仓库固定的 8.0.2 源码核对。
