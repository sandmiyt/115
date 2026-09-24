# iOS 播放器选型：115 原画长视频

检索日期：2026-09-24。以下是公开文档的适配评估，不是同机、同视频的性能排名。SDK 授权费不等于 App 会员费，也不包含云流量等费用。

| 候选 | 与本项目的关系 | 官方公开价格 / 授权 |
| --- | --- | --- |
| KSPlayer 付费版 | 优先试用。AVPlayer + FFmpeg，面向苹果平台的多格式、HDR、字幕播放；付费功能包括进度预览、磁盘预缓存。 | 作者个人方案最低 US$15/月/开发者，首次预付半年 US$90；有收入时按公开方案计算分成。预览、磁盘缓存等功能另外收费，企业询价。 |
| 火山引擎 TTVideoEngine | 优先比较网络播放。提供预加载、自定义请求头和缓存 key，适合评估签名地址更新后的缓存复用。 | 官网点播产品页列基础版 ¥1,999/年；不能将此价格当成包含高级预加载功能的报价，高级版需核对所选 License。 |
| 阿里云播放器 | 提供本地缓存、URL hash、自定义请求头和缓冲阈值；预加载支持网络调度，缓冲不足时让位于当前视频。 | 移动端标准版 ¥999/年/应用，专业版 ¥19,999/年/应用；文档注明预加载需专业版。 |
| 腾讯云播放器 | 支持 iOS 点播、软硬解、视频缓存；需实测原文件封装、音轨及预览来源。 | 移动端基础版 ¥12/年，高级版 ¥899/月。基础版价格不能代表高级功能价格。 |
| Bitmovin | 商业流媒体 SDK；更适合需要 DRM、广告、质量分析的产品，对本项目原文件的收益需实测。 | 当前定价页列 Player 每月 10,000 impressions 免费，超出 US$1.5/千次；实际 iOS 所需功能与额度应以账户方案为准。 |
| Dolby OptiView / THEOplayer | 商业跨平台播放器，提供 iOS/tvOS SDK；对本项目的价值需与其跨平台、DRM 等能力分开评估。 | 官网为定制报价。 |
| mpv / MPVKit | 可控性高，但 iOS 的封装、渲染和维护需自行承担。 | 开源；MPVKit 有 LGPL 和 GPL 构建。其 README 明确定位学习 libmpv、维护不频繁，Metal 为补丁支持，因此暂不作为本项目首选。 |
| VLC / VLCKit | 已有的多格式兼容方案，可作为原画的备用内核。不能据此认定所有视频都比 AVPlayer 快。 | 开源 LGPL。 |
| AVPlayer | 保留苹果原生播放通道。缓冲、拖动、请求策略同样决定实际体验。 | 系统框架，无单独播放器 SDK 授权费。 |

Infuse 是成品 App。其公开第三方 API 是用 URL scheme 跳转到 Infuse 播放；本次未查到可购买后直接嵌入 Cineva 的公开 SDK，不能将购买 Infuse Pro 当成购买内核授权。

优先试用 KSPlayer 付费版，同时用 TTVideoEngine 做网络播放对照。购买前应用同一部 iPhone、同一网络、同一 115 文件测量：首帧时间、20 分钟内停顿次数/总时长、缓存内外跳转耗时、拖动预览响应、温升与内存。原画质量保持不变；预览图速度不能代替实际视频定位耗时。

KSPlayer 公开 GitHub 版本不包含全部付费能力。作者当前公开方案对私有源码分发和持续授权另有要求，付费源码不能直接推入本项目公开 GitHub；接入前需与作者确认适用的授权合同及私有 CI 依赖交付方式。本次没有购买授权、联系供应商或替换内核。

## 一手资料

- [KSPlayer 功能、版本区别](https://github.com/kingslay/KSPlayer)
- [KSPlayer 作者授权与收费说明](https://github.com/kingslay/KSPlayer/issues/731)
- [火山引擎 SDK 概述](https://docs.volcengine.com/docs/video_on_demand/SDKOverview-1?lang=zh)
- [火山引擎点播产品报价](https://www.volcengine.com/product/vod)
- [火山引擎 URL 预加载参数，包括 headers 和 key](https://docs.volcengine.com/docs/video_on_demand/TypeDetails?lang=zh)
- [阿里云计费](https://help.aliyun.com/zh/apsara-video-sdk/billable-items)
- [阿里云 iOS 缓存、预加载和请求头](https://help.aliyun.com/zh/vod/developer-reference/advanced-features-1)
- [腾讯云 License 定价](https://cloud.tencent.com/document/product/881/74588)
- [腾讯云播放器接入说明](https://cloud.tencent.com/document/product/266/58692)
- [Bitmovin iOS SDK](https://bitmovin.com/video-player/ios-sdk/)
- [Bitmovin 定价](https://bitmovin.com/pricing/)
- [Dolby OptiView 定价](https://optiview.dolby.com/plans/)
- [MPVKit](https://github.com/mpvkit/MPVKit)
- [VLCKit](https://github.com/videolan/vlckit)
- [Infuse 第三方调用 API](https://support.firecore.com/hc/en-us/articles/215090997-API-for-Third-Party-Apps-Services)
- [Apple：串行处理 seek 请求](https://developer.apple.com/library/archive/qa/qa1820/_index.html)
- [Apple：前向缓冲设置](https://developer.apple.com/documentation/avfoundation/avplayeritem/preferredforwardbufferduration)

## 2.2.9 的现有内核优化

- AVPlayer 开始播放时交给系统等待可播放缓冲，不再强制立即播放；之后按码率、倍速及短暂卡顿次数提高前向缓冲目标。以 64 MiB 压缩数据估算限制预读时长（8 秒下限）；这是 AVFoundation 的偏好值，不是内存硬上限。
- AVPlayer 拖动过程中保持主解码器不动，松手提交定位。正常播放时从已显示画面采集低分辨率帧，后台转换，缓存最多 160 张/32 MiB。
- 手指移动同步查询缓存；缓存缺失只有一个取帧请求，合并到最新目标，超时取消。预览显示实际采样时间，不冒充精确到每一帧。
- 存在低清转码源时，在连续缓冲至少 20 秒且设备温度、电量模式允许的情况下，每 8 秒最多预取一张，最多 48 张；缓冲不足取消。不会为全片预览扫描远端原画。低清源不支持抽帧时，拖动中可回退到原画按需取帧。
- 缓存命中可直接显示，但没有真机毫秒耗时测量；首次访问未下载位置仍受网络及关键帧解码限制。VLC 拖动路径保留现状。
- 本地只执行静态 preflight 与 diff 检查；Xcode 编译结果另以 GitHub Actions 为准。未增加 regression job/artifact。
# Long-video transport update — 2.2.10 (35)

SenPlayer's published 6.2.0 notes describe segmented disk caching and scrub
previews. This update follows those ideas; it does not contain SenPlayer code
or claim identical performance:
https://apps.apple.com/cn/app/senplayer-media-player/id6443975850

- The previous 64 MiB compressed-buffer estimate left an 80 Mbps original at
  the eight-second floor. AVPlayer now requests 60–120 seconds at normal speed,
  bounded by a 96–256 MiB estimate scaled to physical memory. This is a preference,
  not an enforced AVFoundation memory allocation or a promise of actual runway.
- PlaybackRangeCache serves signed 115 MP4/MOV/M4V originals through
  AVAssetResourceLoader. A single URLSession connection downloads a 512 KiB
  initial probe followed by bounded 32 MiB
  ranges, immediately delivers incoming bytes, and retains partial/completed
  fragments on disk. Cache hits do not make another network request. No preview
  downloader runs ahead in parallel. Other formats, HLS, WebDAV and VLC keep
  their direct transport.
- Temporary disk storage is capped at 512 MiB (less when free space is limited),
  uses LRU eviction, is removed on playback teardown, and has process-start
  orphan cleanup. It is not a permanent offline download; evicted bytes and a
  newly opened playback session can require downloads again.
- Validate HTTP 206, Content-Range start/end/total and validators before serving
  bytes. Unsupported Range responses or disk/transport errors fall back once to
  the same original URL and AVPlayer, preserving position and pause intent.
  Continuous eight-second cache-path waits also permit direct fallback. AirPlay
  picker/route changes bypass the in-process loader. The native AVPlayerLayer,
  HDR path and quality selection remain unchanged.
- Remote preview storyboard scans are disabled, including low-resolution
  transcodes. Existing displayed-frame capture and on-demand paused scrub
  previews remain. Deferred quality discovery waits for ten seconds of runway.
- Preview generation allows a nearby frame within three seconds and labels its
  actual time. Release seeks allow half a second instead of demanding a 100 ms
  window. Continuous disk reads reuse a file descriptor; large HTTP windows
  reduce request round trips. None of these changes claim millisecond decoding
  for uncached remote positions.
- Playback details distinguish contiguous time buffer from retained video bytes;
  download telemetry for the cache path counts upstream URLSession bytes.

Validation: Windows source preflight and Xcode IPA build are separate gates.
Authenticated 115 CDN behavior, sustained original playback, memory pressure,
AirPlay/PiP and touch latency still require device checks. No new regression CI
job/artifact or third-party dependency was added.
