# 原画长视频反复缓冲修复 — 2.3.2 (40)

## 源码检查结论

基线：bc7d1b4，实际发布源码为根目录 Gallery115/。用户确认受影响的是原画/原文件。
尚未取得发生卡顿时的真机诊断或同一视频的网络样本，因此下列是可确认的代码风险，不能当成唯一现场根因。

- 原 AVPlayer 恢复路径在一次真实播放后重新允许 playImmediately，能在每次缓冲等待中绕过系统停顿预测；拖动后又按起播的三秒门槛处理。
- 初始前向缓冲偏好只有三秒，实际时钟推进后才提高预读目标。
- VLC 原画快速模式网络缓存仅 1.8 秒，短暂的 CDN 分段交付间隙就可能耗尽。
- 附加请求在刚出现媒体时间变化后并行开始，关闭快速起播时甚至不等待实际播放；海报仅多等 700ms。

## 修改

- AVPlayer 只在首次起播时允许一次受限的强制起播；暂停、拖动、反复缓冲不重置资格。原画需要八秒连续缓存，转码三秒，随倍速调整，片尾按剩余时长缩短。已知吞吐不足时交给系统决定。
- 从创建播放器项目起就请求按码率/设备内存计算的前向缓存。该值是 AVFoundation 偏好，不是强制下载量、内存硬上限或首帧必须等待的时长。
- VLC 保留同一原文件，网络缓存改为快速模式五秒、稳定模式八秒。更大的缓存可能增加首次起播/未缓存位置定位等待，需要真机权衡。
- 字幕、章节、海报、完整播放列表依次等待连续五秒实际播放和十五秒连续缓存（随倍速调整，以预读目标的 75% 及剩余时长为上限，避免高码率媒体永远达不到门槛）。VLC 没有该缓存读数，使用连续实际播放作为门槛；不会伪造缓存值。
- 初始历史位置 seek 未完成时不自动切内核。保留重复缓冲/长时间停顿时的同原画 VLC 备用路径。
- 没有降低原画码率、分辨率，没有更换硬解码/渲染路径。mpv 曾因崩溃被基线提交撤回，本次未再次接入。

## 验证方法

Windows：`python Tests/preflight.py` 和 `git diff --check`。

macOS / GitHub 现有 build 作业：

```sh
xcrun swiftc Gallery115/Models/CloudItem.swift \
  Gallery115/Models/PlaybackRecoveryPolicy.swift \
  Tests/PlaybackPolicyTests.swift -o /tmp/playback-policy-tests
/tmp/playback-policy-tests
```

直接编译发布使用的 Swift 策略，覆盖原画/转码门槛、倍速、低吞吐、缓存空洞、短片尾、非法读数、暂停/seek 后不强制重启、恢复事件窗口、附加请求门槛和 VLC 缓存。两小时状态遍历只验证策略不变量，不模拟 AVPlayer 或真实网络，不作为播放性能数字。

之后执行完整 VLC iPhone Release 编译并打包 unsigned IPA。沿用一个 build 作业及一个 IPA artifact，没有新增 regression 作业或结果 artifact。

## 尚需真机验证

同一 iPhone、网络、原文件分别选系统内核和 VLC，连续播放至少二十分钟，记录播放详情中的首帧时间、停顿次数、吞吐与媒体码率；覆盖缓存内外跳转、暂停后恢复、倍速、后台/前台、PiP/AirPlay。验证原文件画质和播放位置保持不变。持续下载速度低于视频消耗速度时，缓存只能缓解波动，不能承诺消除所有停顿。

## 官方行为依据

- Apple: [playImmediately(atRate:)](https://developer.apple.com/documentation/avfoundation/avplayer/playimmediately(atrate:)) 会立即使用已有缓冲，不能据此认定系统已判断缓存充分。
- Apple: [preferredForwardBufferDuration](https://developer.apple.com/documentation/avfoundation/avplayeritem/preferredforwardbufferduration) 为前向缓冲偏好。
- VideoLAN: [VLC 3.0 配置定义](https://videolan.videolan.me/vlc-3.0/libvlc-module_8c.html) 的 network-caching 单位为毫秒。
