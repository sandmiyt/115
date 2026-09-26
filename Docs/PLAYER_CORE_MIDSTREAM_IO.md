# 2.2.9（48）：中段取包与缓冲修正

## 证据与判断

47 版用户日志：H.264 Main（Profile 77）、1920×1080、8 位、BT.709，AAC 音轨；实际 VideoToolbox 硬解，显示入队约 400 帧，无显示恢复/丢帧/终止错误。约 632 秒处压缩包与视频帧队列均为空，读取线程位于 av_read_frame，解码线程等待任务。用户确认从头开始暂未发现问题，播放至中段或直接定位至中段反复缓冲。

该快照支持“取包端供应不足”，不支持“已确证 HDR 渲染失败”。当前 source 没有 PQ/HLG 标记，也不能用它证明用户原文件一定没有 HDR。没有该私人视频及 HTTP 实测，尚不能在服务端限速、Range 响应、MP4 轨道布局与中段索引之间确定唯一根因。

FFmpeg 8.0.2 的 MOV 读取会按轨道时间挑选样本；轨道数据布局不佳时，HTTP 跳转可能频繁发生。官方也明确记录了该问题。没有将 `interleaved_read=0` 作为通用解法：对完全分离的音视频轨，它可能导致长时间只读一个轨道。当前仍验证选中视频和音频两个解码器。

## 实现

- HTTP 启用 multiple_requests 连接复用；short_seek_size 调至 1 MiB，小幅前向跳转优先继续读取，降低重新定位请求开销。
- rw_timeout 调至 3 秒；允许 seekable HTTP 在断开/连接错误后从当前位置有限重连，最多 2 次重试、单次退避不超过 1 秒、累计退避不超过 2 秒；保留外层读取/定位 10 秒与打开 30 秒的截止时间。不重连正常 EOF，不允许流式源从头重连，不无限重试鉴权错误。
- 解封装阶段把未选中的轨道设为 AVDISCARD_ALL，避免下载之后才丢弃。选中视频和音轨都保留。
- 压缩队列按视频包时长计量，上限为 8 秒/512 个包/16 MiB 任一先达到；之前的 4 秒同时累计视频与音频，常只覆盖约 2 秒真实播放时间。已解码帧队列仍是既有 3/6 帧上限。首帧不等待队列填满。
- seek 期间也检查 generation，新拖动可中断旧定位；旧定位被中断不能覆盖新请求或报告成媒体损坏。
- 新诊断：AVIO 累计读入字节、当前文件位置、当前 I/O 操作耗时、最近取包耗时、距上个选中包的时间、包位置回退/大幅前跳次数、压缩视频队列时长。包位置变化不是 HTTP 请求计数；AVIO 字节也不是网络线上精确传输量。计数由读取线程复制，不从 UI 线程访问可变 AVIOContext。

这些均使用固定 FFmpeg 8.0.2 中存在的选项。较新官方文档里的 request_size/initial_request_size 不在此版本 http.c 中，未添加无效选项，也未声称实现了自定义 Range 块缓存。

## 文件与验证

- `Dependencies/FFmpeg/Bridge/CinevaFFmpegSession.c`、`.h`：HTTP 策略、解封装丢弃、队列预算、seek 取消、I/O 快照。
- `Gallery115/PlayerCore/FFmpegDecodeSession.swift`、`Gallery115/Player/FFmpegDecodeValidationView.swift`：读取诊断显示与复制。
- Xcode project：版本 2.2.9（48）。

本地现有源码 preflight、Bash 语法及 diff 检查；FFmpeg C/Swift 编译、链接和 IPA 打包由 GitHub macOS 执行，以对应最终提交的运行结果为准。未新增 regression 脚本/作业/产物。没有在 Windows 上执行该文件的真机播放或声称已确认修复。

真机重点：在同一视频约 600–650 秒附近播放和前后定位；连续拖动后应保留最后目标；对照原先正常的视频。若仍卡顿，复制诊断看“当前 I/O / 距上次包”、文件位置和包位置跳变是否持续增长。无声验证入口以外的日常 AVPlayer/VLC 不受本次 HTTP 选项影响。

参考：[FFmpeg 官方对 MP4 轨道交错导致 HTTP seek 缓慢的说明](https://ffmpeg.org/pipermail/ffmpeg-cvslog/2023-September/138841.html)、[HTTP 协议选项](https://ffmpeg.org/ffmpeg-protocols.html)，并核对固定 8.0.2 源码包中的 `http.c`、`mov.c`、`aviobuf.c` 和 `avio.h`。
