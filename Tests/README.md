# 封面持久缓存 / 起播竞争修复验证

## 实现与边界

- 封面存放在 `Library/Application Support/CinevaArtwork`，不设 TTL，不做容量自动淘汰，排除 iCloud 备份；内存缓存仍有上限。
- 磁盘键包含完整 WebDAV 端点、账号、挂载路径、文件路径、大小、修改时间；不包含临时封面 URL、密码或 WebDAV ETag。
- 旧 `Library/Caches/GeneratedThumbnails` 会迁入持久目录，再按旧键按需转换。旧版本未保存服务器身份，因此旧缓存只归属首次访问它的连接；无法反查的旧 ETag 文件不能可靠匹配，需要重建一次。
- 只有缓存缺失、损坏、文件信息变化，或用户手动清除/卸载，才重新获取封面。卸载重装不等于覆盖安装，无法保留 App 沙盒。
- 整条缩略图网络流水线最多 2 个任务；重复请求合并，最后一个消费者取消时停止任务，播放页持有优先权时停止远程封面工作。本地封面命中不受影响。
- 抽帧取消会停止 AVFoundation 请求；取靠近开头的帧，不再先加载完整时长以计算百分比时间点。
- 快速起播时，播放器旁路请求等待实际播放时间推进再启动。不修改 AVPlayer/VLC、115 登录、Token、WebDAV 302取流、播放记录、收藏和队列规则。
- WebDAV 元数据查询被取消时不写入“没有元数据”的负缓存，防止停止后台封面任务后使播放器海报/信息被误判为空。
- 日志类别 `PlaybackStartup` 分别记录交给内核、释放旁路请求的耗时；不记录账号、URL或签名。这不是像素级首帧测量。
- 不承诺固定起播秒数：OpenList/115的冷解析和CDN首字节延迟仍需同一网络下实测。

## iOS 运行测试（需 Mac + Xcode）

根目录 `Package.swift` 仅用于验证，直接编译真实缓存实现，网络/凭据边界使用测试替身。不会改变 App 的 CocoaPods 构建。

1. 在 Xcode 打开根目录 `Package.swift`，选择 `CinevaCacheValidation` scheme 和任意 iOS 17+ 模拟器。
2. 执行 Product → Test；应运行 18 个 XCTest。
3. 命令行也可先运行 `xcodebuild -list` 确认自动生成的 scheme，再执行：

```sh
xcodebuild -scheme CinevaCacheValidation \
  -destination 'platform=iOS Simulator,name=你的模拟器名称' \
  -resultBundlePath build/CacheRegression.xcresult \
  -test-timeouts-enabled YES -maximum-test-execution-time-allowance 60 test
```

测试覆盖：重建服务后磁盘命中且网络调用为0、数月旧文件不过期、签名/ETag变化、挂载/账号隔离、文件替换、旧缓存迁移、损坏修复、并发去重/限流、播放抢占/恢复、排队取消、清理期间迟到回调不复活文件、写盘失败、实际AVFoundation本地视频抽帧。

## 本机源码预检（不等同于 Xcode 编译/运行）

```powershell
python -m pip install --target .validation-tools tree-sitter==0.26.0 tree-sitter-swift==0.7.3
python Tests/preflight.py
git diff --check
```

## 真机验收

1. **覆盖安装**更新版本，保持 bundle ID 不变。不要先卸载。
2. 在资源库等待一组封面显示，查看“设置 → 缓存 → 本地封面”占用。
3. 强制退出 App，断开网络，再打开已经缓存的资源库：同一组封面应显示，不依赖115或签名链接。
4. 保持原文件不变，等待一天或刷新OpenList ETag，再次打开验证；若真实文件大小/修改时间变化，重建封面是预期行为。
5. 缩略图正在生成时打开视频，返回后确认未完成封面继续加载；重复快速打开、退出、切换视频。
6. 同一视频、相同续播位置、相同网络分别测冷启动和重复打开。记录修改前后实际等待时间，不用 UI 转圈时长推断网络根因。
7. 验证 AVPlayer 的 MP4 与 VLC 的 MKV、续播、暂停、字幕、队列、锁定、后台/恢复和旋转均未回归。

## 参考

- Apple 非可清理数据与备份排除：https://developer.apple.com/documentation/foundation/optimizing-your-app-s-data-for-icloud-backup
- Nuke 的内存/磁盘分层、请求合并与优先级：https://github.com/kean/Nuke
- SDWebImage 自定义缓存键：https://github.com/SDWebImage/SDWebImage/blob/master/SDWebImage/Core/SDWebImageManager.m

采用以上原则做局部实现，没有新增运行时第三方图片库。
