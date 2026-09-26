# 第 3 阶段：FFmpeg 解封装与软件解码验证

版本：2.2.9（44）。用户在 43 号构建交付后要求继续下一阶段；上一版具体真机测量结果未提供，本阶段也不能把编译成功当作设备验收。

## 已实现的实际链路

播放详情 → FFmpeg 解码验证（无声） → 复用当前 VideoSource URL/headers → FFmpeg HTTP 输入 → avformat 解封装线程 → 有界压缩包队列 → avcodec 软件视频/音频解码线程 → CVPixelBuffer 帧队列 → AVSampleBufferDisplayLayer。

此入口不使用 AVPlayer/VLC 解码或生成视频帧。它不是 metadata-only 探测。UI 不 import FFmpeg；只有 PlayerCore 的适配器和 C 桥依赖该库。

- C 桥使用 opaque session，隐藏所有 libav 符号；框架继续由固定 SHA256 的 FFmpeg 8.0.2 官方源码构建，保持 LGPL 配置。
- 读线程和解码线程分离；有序混合队列保留原文件音视频包交错顺序。压缩队列最多 256 包 / 16 MiB / 约 4 秒累计包时长，显示帧最多 6 帧。单个超过 16 MiB 的压缩包显式失败；不是无限增长的缓存。
- 正确处理 send/receive 的 EAGAIN、EOF drain、seek flush；音频真实解码并计数，目前丢弃 PCM，不假装有音频输出。
- seek 递增 serial，取消旧读取、清空队列，avformat_seek_file 定位关键帧、flush codec、丢弃目标之前的帧，显示端再次检查 serial。
- 打开/探测共 30 秒期限，每次读取/定位 10 秒期限。取消通过 AVIOInterruptCB 中断。退出先停显示消费，再在后台 join 两个工作线程并释放全部对象，主线程不等待网络退出。
- 软件解码线程数限定为 2；视频接受到 4096×2304，验证显示缩放到最高 1280×720 BGRA CVPixelBuffer。这里有 swscale CPU 转换，**不是零拷贝，也不是最终硬件渲染路径**。无 UIImage/CGImage 逐帧转换。
- 原生显示层按媒体 PTS + host-clock timebase 调度。CADisplayLink 只补充最多约 250 ms 的待显示帧，不用 Timer 合成帧率。支持暂停、松手定位、±10 秒和结束后重播。
- HDR PQ/HLG 当前显式拒绝，保留原播放器路径，避免伪造 HDR 或错误强制映射 SDR。旋转矩阵用于验证画面布局。
- 展示真实输出帧计数、音频解码计数、队列大小、首帧/定位入显示队列耗时。耗时不是屏幕光学首帧测量，也不是音画同步指标。

## 保留旧功能与入口边界

该入口在「播放详情 → FFmpeg 解码验证（无声）」，主动打开才创建线程；普通播放默认仍使用 AVPlayer/VLC。进入时暂停原播放器并暂时隔离其传输控制；返回后按播放继续原视频，验证位置不覆盖历史。

验证页离开、进入后台或触发隐私锁时结束会话。日常 115 登录/浏览/缩略图、历史、字幕、倍速、PiP、后台、锁屏控制和 AirPlay 继续由原有播放器提供。当前验证路径没有这些完整能力，不能作为默认播放器。

## 115 网络与缓存边界

复用当前 provider 的 URL、User-Agent、Cookie/其他有效 headers；校验请求头换行，日志不输出签名 URL/凭据。当前由 FFmpeg 自带 HTTP 协议负责网络读取和 seek，限制协议为 HTTP/HTTPS 及其底层 TCP/TLS/crypto。

**尚未实现自定义 AVIO、应用级 Range 缓存、过期 URL 刷新或验证跨 CDN 的真实缓存命中。** 队列字节只是等待解码的压缩数据，不是磁盘缓存。打开验证会额外建立一条 FFmpeg 网络会话；原播放器虽暂停，系统可能仍保留其预读，因此此入口不是最终网络性能对照环境。

## 文件清单

- `Dependencies/FFmpeg/Bridge/CinevaFFmpegSession.c`：线程、队列、解封装、视频/音频软解、取消、seek、帧转换与对象释放。
- `Dependencies/FFmpeg/Bridge/CinevaFFmpeg.h`：不透明会话 C ABI、值类型诊断和 CVPixelBuffer 所有权。
- `Dependencies/FFmpeg/build-apple.sh`：编译新桥接源，导出白名单更新。
- `Gallery115/PlayerCore/FFmpegDecodeSession.swift`：会话所有权、状态、时间基、帧输出及诊断。
- `Gallery115/Player/FFmpegDecodeValidationView.swift`：真实媒体验证入口及操作。
- `Gallery115/Views/PlayerScreen.swift`：播放详情入口和原播放器暂停/控制隔离。
- `Gallery115/PlayerCore/FFmpegRuntime.swift`、`Gallery115/Views/SettingsView.swift`：阶段说明更新。
- `Gallery115.xcodeproj/project.pbxproj`：注册编译源，版本 44。

## 尚未完成

本阶段没有新增实际硬解 codec；VideoToolbox 仍只是上阶段编译进库。第 4 阶段才创建硬件解码会话和失败 fallback。最终原生/Metal 视频路径、音频输出/音频主时钟/倍速音调保持、自定义 AVIO 和缓存、独立音视频解码队列、轨道切换、完整字幕、HDR/Dolby 和自定义 PiP/AirPlay 仍在后续阶段。

软件验证有可能比原播放器慢或更耗电；不能用它证明长视频卡顿已修复，也不承诺毫秒级 seek 或秒开。

## 验证与真机清单

本地执行现有 preflight、Bash 语法检查和 diff 检查。Windows 不能执行 Apple 编译/模拟器。GitHub macOS 负责真实 C/Swift 编译和 IPA 打包，结果以本次交付消息和提交运行记录为准。没有新增 regression 作业、脚本或产物。

安装后：

1. 确认版本 44，普通 AVPlayer/VLC 播放、原画选项、历史、字幕及 PiP 仍正常。
2. 打开同一 115 SDR H.264/HEVC 长视频，在播放详情进入无声验证。确认有连续画面、实际视频/音频计数增长，记录首帧入队耗时。
3. 播放与暂停各拖动十次，测试快速连续 ±10 秒、远距离定位、文件尾部和重播。确认不返回旧画面，暂停时 seek 不自行播放。
4. 连续开关验证页十次，断网后退出、锁屏/退后台后返回；确认 App 不闪退、不继续在后台软解。
5. 验证 HDR 文件有明确不支持提示并能返回原播放器；不要以软件验证页验收 HDR/音频/PiP。
6. 检查 MKV 多音轨文件能解码默认轨、无音轨文件可出画面、竖屏旋转正确；记录不支持的文件与错误码，不发送 URL 或账号凭据。

参考：[FFmpeg send/receive 协议](https://ffmpeg.org/doxygen/8.0/group__lavc__encdec.html)、[中断回调](https://ffmpeg.org/doxygen/8.0/structAVIOInterruptCB.html)、[Apple 显示时间基](https://developer.apple.com/documentation/avfoundation/avsamplebufferdisplaylayer/controltimebase)。
