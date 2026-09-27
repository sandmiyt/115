import AVFoundation
import CinevaFFmpeg
import CryptoKit
import CoreImage
import Observation
import UIKit
import Darwin

/// The normal screen's FFmpeg backend. It owns C workers, real PCM output and
/// an audio-render-clock-driven native video surface; AVPlayer is not wrapped.
@MainActor @Observable
final class FFmpegPlayerEngine: PlayerEngine, PlayerTrackSelecting {
  private(set) var playbackState: PlayerState = .idle
  private(set) var currentTime = 0.0
  private(set) var duration = 0.0
  private(set) var bufferedUntil = 0.0
  private(set) var volume: Float = 1
  private(set) var rate: Float = 1
  private(set) var wantsPlayback = true
  private(set) var statistics = PlayerStatistics(backend:.ffmpeg)
  private(set) var diagnostics = "FFmpeg 正在准备"
  @ObservationIgnored private var preferHardware=true
  @ObservationIgnored private var playbackBeganAt:Double?
  @ObservationIgnored private var audioRenderedAt:Double?
  @ObservationIgnored private var displayReadyAt:Double?
  @ObservationIgnored private var uninterruptedAt:Double?
  @ObservationIgnored private var stableAt:Double?
  @ObservationIgnored private var sourceResolvedAt=0.0
  @ObservationIgnored private var clickAt=0.0
  @ObservationIgnored private var cpuSeconds=0.0
  @ObservationIgnored private var usageAt=0.0
  @ObservationIgnored private var commitAt:Double?
  @ObservationIgnored private var localSeek=false
  @ObservationIgnored private var seekRequests=0
  @ObservationIgnored private var dragIO:RangeStatistics?
  @ObservationIgnored private var seekIO:RangeStatistics?
  @ObservationIgnored private var seekBegan=0.0
  @ObservationIgnored private var seekGeneration:Int32=0
  @ObservationIgnored private var seekAudioMilliseconds:Double?
  private(set) var seekDiagnostic="尚未拖动"
  private(set) var finalSeekCount=0
  private(set) var seekFrameMilliseconds:Double?
  @ObservationIgnored private var scrubbing=false
  @ObservationIgnored private var scrubIntent=false
  @ObservationIgnored private let preview=FFmpegTimelinePreview()
  var timelinePreview:TimelinePreviewController { preview.display }
  private(set) var errorMessage: String?
  private(set) var lastFailure: FFmpegFailureSnapshot?
  @ObservationIgnored private var sessionID=UUID()
  private(set) var inputBackend: FFmpegInputBackend = .customAVIOCached
  private(set) var videoSize: CGSize?
  private(set) var rotation = 0.0
  private(set) var audioUnderruns = 0
  private(set) var rebufferCount = 0
  private(set) var audioTracks: [PlayerTrack] = []
  private(set) var subtitleTracks: [PlayerTrack] = []
  private(set) var selectedAudioOptionID: String?
  private(set) var selectedSubtitleOptionID: String?
  private(set) var subtitleImage: UIImage?
  private(set) var subtitleWarning: String?
  private(set) var hasAtmosMetadata = false
  var subtitleDelay = 0.0
  var subtitleTextEncoding = "自动"
  @ObservationIgnored private var subtitleEpoch = UUID()
  @ObservationIgnored private var subtitleTask: Task<Void,Never>?
  @ObservationIgnored private var lastSubtitleRender = 0.0
  private(set) var isInteractiveScrubLoading = false
  let renderer = NativeVideoRenderer()
  private(set) var audio = NativeAudioRenderer()
  private(set) var pip: FFmpegPiPController?
  init() { pip=FFmpegPiPController(engine:self) }
  var currentSource: VideoSource?
  var isPlaying: Bool { playbackState == .playing }
  var isBuffering: Bool { playbackState.needsLoadingIndicator }
  var didReachEnd: Bool { playbackState == .ended }
  var bufferedDuration: Double { max(0,bufferedUntil-currentTime) }
  var networkMbps: Double { statistics.networkMbps ?? 0 }
  var transferredMegabytes: Double { Double(statistics.downloadedBytes ?? 0)/1048576 }
  var loadingFeedback: PlayerLoadingFeedback? {
    guard isBuffering || playbackState == .seeking else { return nil }
    return PlayerLoadingFeedback(delayMilliseconds:200,generation:Int(serial))
  }
  @ObservationIgnored private var handle: FFmpegSessionHandle?
  @ObservationIgnored private var ticker: Timer?
  @ObservationIgnored private var pending: (CVPixelBuffer,Double,Double,Int32)?
  @ObservationIgnored private var samples = [Float](repeating:0,count:131072)
  @ObservationIgnored private var serial: Int32 = 1
  @ObservationIgnored private var waiting = true
  @ObservationIgnored private var hasAudio = false
  @ObservationIgnored private var target = 0.0
  @ObservationIgnored private var resumeTarget = 0.75
  @ObservationIgnored private var waitStarted = 0.0
  @ObservationIgnored private var lastPublished = 0.0
  @ObservationIgnored private var lastPump = 0.0
  @ObservationIgnored private var firstFrameAt: Double?
  @ObservationIgnored private var startAt = 0.0
  @ObservationIgnored private var sourceItem: CloudItem?
  @ObservationIgnored private var library: LibraryStore?
  @ObservationIgnored private var api: APIClient?
  @ObservationIgnored private var savedSecond = -1
  @ObservationIgnored private var lastRemoteSave = -60
  @ObservationIgnored private var observers: [NSObjectProtocol] = []
  @ObservationIgnored private var interruptedIntent = false
  @ObservationIgnored private var cache: RangeCoordinator?
  @ObservationIgnored private var lastNetworkBytes: Int64 = 0
  @ObservationIgnored private var lastNetworkAt = 0.0
  @ObservationIgnored private var audioTail = false
  @ObservationIgnored private var backgroundAudioOnly = false
  @ObservationIgnored private var restoredAudioPreference = false
  @ObservationIgnored private var defaultAudioID: String?
  @ObservationIgnored private var audioPreferenceKey: String?
  @ObservationIgnored private var recordsHistory = true
  @ObservationIgnored private var lifecycleEpoch = UUID()
  @ObservationIgnored private var toneMapTask: Task<Void,Never>?
  @ObservationIgnored private var pendingToneMapped = false
  @ObservationIgnored private let toneMapper = FFmpegSDRToneMapper()
  private(set) var toneMappedSDR = false

  static func cacheIdentity(for item:CloudItem)->RangeCacheIdentity {
    let scope: String
    if MediaSourceSelectionStore.shared.resolvedSource == .cloud115 {
      // Account API has no stable user identifier in the current auth model.
      // Hash the authenticated session, sacrificing reuse after rotation rather
      // than sharing cached private bytes between accounts.
      let token=Cloud115SessionStore.shared.session?.refreshToken ?? UUID().uuidString
      scope="115-session:"+SHA256.hash(data:Data(token.utf8)).map { String(format:"%02x",$0) }.joined()
    } else { scope=ThumbnailService.currentNamespace() }
    return RangeCacheIdentity(account:scope,fileID:item.id,size:item.size,
      validator:item.sha1.isEmpty ? "" : "sha1:"+item.sha1.lowercased())
  }
  static func cachedSource(for item:CloudItem) async -> VideoSource? {
    let identity=cacheIdentity(for:item)
    guard identity.isPersistent else { return nil }
    let complete=await Task.detached(priority:.userInitiated) {
      SegmentDiskCache.shared.restored(identity:identity.key)?.complete == true
    }.value
    guard complete,!Task.isCancelled else { return nil }
    return VideoSource(id:"offline-"+identity.key,title:"原画 · 本地缓存",definition:0,
      url:URL(string:"cineva-cache://media/"+identity.key)!,kind:.original,headers:[:])
  }
  private(set) var mediaCacheProgress=MediaCacheProgress()
  var mediaCacheText:String {
    guard inputBackend == .customAVIOCached else { return "当前视频使用在线播放" }
    let p=mediaCacheProgress
    if let message=p.limitation { return message+" · 已缓存 \(ByteCountFormatter.string(fromByteCount:p.bytes,countStyle:.file))" }
    guard p.total>0 else { return "正在确认视频缓存" }
    let size=ByteCountFormatter.string(fromByteCount:p.bytes,countStyle:.file)
    let total=ByteCountFormatter.string(fromByteCount:p.total,countStyle:.file)
    return p.complete ? (p.persistent ? "整片已缓存 · \(total)" : "本次播放已全部落盘 · \(total)")
      : "已缓存 \(size) / \(total) · \(Int(Double(p.bytes)/Double(p.total)*100))%"+(p.persistent ? "" : " · 重开需在线验证")
  }
  func start(source: VideoSource, item: CloudItem, api: APIClient, library: LibraryStore,
             at position: Double, playing: Bool = true, useCache: Bool = true, preferHardware: Bool = true,
             recordsHistory: Bool = true, inputBackend: FFmpegInputBackend? = nil, startupOrigin:Double? = nil) {
    stop()
    sessionID=UUID(); mediaCacheProgress=MediaCacheProgress()
    self.inputBackend=inputBackend ?? PlaybackPolicy.input(for:source)
    self.recordsHistory=recordsHistory
    currentSource=source; sourceItem=item; self.api=api; self.library=library
    target=max(0,position.isFinite ? position : 0); currentTime=target
    self.preferHardware=preferHardware
    sourceResolvedAt=CACurrentMediaTime(); clickAt=startupOrigin ?? sourceResolvedAt
    playbackBeganAt=nil; audioRenderedAt=nil; displayReadyAt=nil; stableAt=nil; uninterruptedAt=nil
    finalSeekCount=0; seekFrameMilliseconds=nil; commitAt=nil
    localSeek=false; seekIO=nil; dragIO=nil; seekGeneration=0; seekDiagnostic="尚未拖动"
    wantsPlayback=playing; waiting=true; resumeTarget=0.75; serial=1
    backgroundAudioOnly=false
    rebufferCount=0; audioUnderruns=0; firstFrameAt=nil
    audioTracks=[]; selectedAudioOptionID=nil; audioTail=false; restoredAudioPreference=false
    defaultAudioID=nil; audioPreferenceKey=nil
    subtitleTracks=[]; selectedSubtitleOptionID=nil; subtitleWarning=nil
    hasAtmosMetadata=false
    toneMappedSDR=false
    errorMessage=nil; startAt=CACurrentMediaTime(); waitStarted=startAt
    lastPublished=0; lastNetworkAt=startAt; lastNetworkBytes=0
    duration=item.duration; playbackState = .preparing
    renderer.reset(to:target,newSession:true); audio.reset(to:target,generation:serial)
    guard source.headers.allSatisfy({ !$0.key.contains(where: \.isNewline) && !$0.value.contains(where: \.isNewline) && !$0.key.contains(":") }) else {
      fail("媒体请求头格式无效"); return
    }
    var options = CinevaFFmpegSessionOptions()
    options.preferHardware=preferHardware ? 1 : 0; options.videoOnly=0; options.outputAudio=1
    if self.inputBackend != .ffmpegHTTP {
      let identity=Self.cacheIdentity(for:item)
      audioPreferenceKey="cineva.ffmpeg.audio."+identity.key
      let coordinator=RangeCoordinator(source:source,identity:identity,cacheEnabled:self.inputBackend == .customAVIOCached,refresh:{
        let response=try await api.initialVideoSources(for:item,preferOriginal:true)
        guard let fresh=response.sources.first(where: \.isOriginal) else { throw URLError(.resourceUnavailable) }
        return fresh
      })
      cache=coordinator; options.attach(coordinator)
    }
    let headers=source.headers.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)\r\n" }.joined()
    let pointer=source.url.absoluteString.withCString { url in
      headers.withCString { CinevaFFmpegSessionCreate(url,$0,target,options) }
    }
    guard let pointer else { fail("无法创建 FFmpeg 会话"); return }
    handle=FFmpegSessionHandle(pointer,io:cache)
    preview.configure(source:source,coordinator:cache)
    audio.setRate(rate); audio.setVolume(volume)
    installObservers()
    let timer=Timer(timeInterval:1.0/60,repeats:true) { [weak self] _ in
      MainActor.assumeIsolated { self?.pump() }
    }
    RunLoop.main.add(timer,forMode:.common); ticker=timer
  }
  func stop() {
    lifecycleEpoch=UUID()
    toneMapTask?.cancel(); toneMapTask=nil; pendingToneMapped=false
    toneMapper.reset()
    resetSubtitleImage()
    pip?.stop()
    scrubbing=false; preview.stop()
    saveProgress(force:true)
    ticker?.invalidate(); ticker=nil
    audio.stop(); renderer.reset(to:currentTime); pending=nil
    handle=nil; cache?.close(); cache=nil
    observers.forEach(NotificationCenter.default.removeObserver); observers.removeAll()
    mediaCacheProgress=MediaCacheProgress()
    playbackState = .stopped
  }
  func pause() {
    if scrubbing { scrubIntent=false; cancelInteractiveScrub() }
    wantsPlayback=false; audio.pause(); renderer.setPlaying(false)
    playbackState = .paused; saveProgress(force:true)
  }
  func resume() {
    wantsPlayback=true
    if !waiting {
      do { if hasAudio { try audio.resume() }; renderer.setPlaying(true); playbackState = .playing }
      catch { fail("系统音频输出无法启动：\(error.localizedDescription)") }
    } else { playbackState = .buffering }
  }
  func togglePlayback() { wantsPlayback ? pause() : resume() }
  func clearSegmentCache() async {
    guard let source=currentSource, let item=sourceItem, let api, let library else { return }
    let position=currentTime, playing=wantsPlayback, record=recordsHistory
    let backend=inputBackend, hardware=preferHardware
    stop()
    let epoch=lifecycleEpoch
    await Task.detached(priority:.utility) { SegmentDiskCache.shared.clear() }.value
    guard lifecycleEpoch==epoch else { return }
    start(source:source,item:item,api:api,library:library,at:position,playing:playing,preferHardware:hardware,recordsHistory:record,inputBackend:backend)
  }
  func setPlaybackRate(_ value: Float) {
    rate=min(2,max(0.5,value)); audio.setRate(rate)
    renderer.alignClock(to:currentTime,rate:Double(rate),running:isPlaying)
  }
  func setVolume(_ value: Float) { volume=min(1,max(0,value)); audio.setVolume(volume) }
  func seek(to seconds: Double) {
    if scrubbing { cancelInteractiveScrub() }
    resetSubtitleImage()
    toneMapTask?.cancel(); toneMapTask=nil; pendingToneMapped=false
    guard let handle, seconds.isFinite else { return }
    cache?.allowPrefetch(false)
    target=min(max(0,seconds),duration>0 ? max(0,duration-0.01) : max(0,seconds))
    let io=cache?.statistics
    seekIO=dragIO ?? io; dragIO=nil; seekRequests=io?.requests ?? 0
    localSeek=cache?.mediaCacheProgress.complete == true
    seekBegan=CACurrentMediaTime(); commitAt=seekBegan
    seekFrameMilliseconds=nil; seekAudioMilliseconds=nil
    // Stop already scheduled old audio before publishing a new generation.
    audio.pause(); renderer.setPlaying(false)
    serial=CinevaFFmpegSessionSeek(handle.pointer,target)
    seekGeneration=serial
    audio.reset(to:target,generation:serial); renderer.reset(to:target,preservingImage:true)
    pending=nil; currentTime=target; waiting=true; resumeTarget=0.75
    audioTail=false
    waitStarted=CACurrentMediaTime(); playbackState = .seeking
  }
  func replayFromStart() { wantsPlayback=true; seek(to:0) }
  func beginInteractiveScrub() -> Bool {
    guard !scrubbing else { return scrubIntent }
    cache?.allowPrefetch(false)
    dragIO=cache?.statistics
    scrubIntent=wantsPlayback; scrubbing=true
    audio.pause(); renderer.setPlaying(false) // Keep PCM, frame queues and real position.
    wantsPlayback=false; isInteractiveScrubLoading=false
    preview.begin(at:currentTime)
    return scrubIntent
  }
  func interactiveScrub(to seconds:Double) {
    guard scrubbing else { return }
    preview.update(min(max(0,seconds),duration>0 ? max(0,duration-0.001) : max(0,seconds)))
  }
  func endInteractiveScrub(to seconds:Double,resumeAfter:Bool) {
    guard scrubbing else { return }
    preview.finish(keepOverlay:true); scrubbing=false
    wantsPlayback=resumeAfter; finalSeekCount += 1
    seek(to:seconds) // The only primary seek in a drag lifecycle.
  }
  func cancelInteractiveScrub() {
    guard scrubbing else { return }
    preview.finish(keepOverlay:false); scrubbing=false
    dragIO=nil
    wantsPlayback=scrubIntent
    if scrubIntent { resume() } else { playbackState = .paused }
  }
  func selectAudio(_ id: String?) {
    guard let selected=id ?? defaultAudioID, let index=Int32(selected), let handle else { return }
    if selected==selectedAudioOptionID { return }
    resetSubtitleImage()
    toneMapTask?.cancel(); toneMapTask=nil; pendingToneMapped=false
    audio.pause(); renderer.setPlaying(false)
    let next=CinevaFFmpegSessionSelectAudio(handle.pointer,index)
    guard next>0 else { if wantsPlayback { resume() }; return }
    serial=next; target=currentTime; audio.reset(to:target,generation:next); renderer.reset(to:target)
    pending=nil; waiting=true; resumeTarget=0.75; waitStarted=CACurrentMediaTime(); audioTail=false
    playbackState = .seeking
    if recordsHistory, let key=audioPreferenceKey {
      if let id { UserDefaults.standard.set(id,forKey:key) }
      else { UserDefaults.standard.removeObject(forKey:key) }
    }
  }
  func selectSubtitle(_ id: String?) {
    guard let handle else { return }
    let index=id.flatMap(Int32.init) ?? -1
    let next=CinevaFFmpegSessionSelectSubtitle(handle.pointer,index)
    guard next>0 else { subtitleWarning="字幕轨无法选择"; return }
    selectedSubtitleOptionID=id; subtitleWarning=nil; resetSubtitleImage()
    toneMapTask?.cancel(); toneMapTask=nil; pendingToneMapped=false
    audio.pause(); renderer.setPlaying(false)
    serial=next; target=currentTime; audio.reset(to:target,generation:next); renderer.reset(to:target)
    pending=nil; waiting=true; resumeTarget=0.75; waitStarted=CACurrentMediaTime(); audioTail=false
    playbackState = .seeking
  }
  private func resetSubtitleImage() {
    subtitleEpoch=UUID(); subtitleTask?.cancel(); subtitleTask=nil; subtitleImage=nil; lastSubtitleRender=0
  }
  func loadExternalSubtitle(data: Data, fileExtension: String) async throws {
    guard let handle else { throw URLError(.resourceUnavailable) }
    guard !data.isEmpty else { throw URLError(.cannotDecodeContentData) }
    let normalized:Data
    if fileExtension.lowercased()=="sup" {
      guard data.count<=8*1024*1024 else { throw URLError(.dataLengthExceedsMaximum) }
      normalized=data
    } else {
      guard data.count<=4*1024*1024 else { throw URLError(.dataLengthExceedsMaximum) }
      let gb=String.Encoding(rawValue:CFStringConvertEncodingToNSStringEncoding(0x0632))
      let big5=String.Encoding(rawValue:CFStringConvertEncodingToNSStringEncoding(0x0A03))
      let choices:[String:String.Encoding]=["UTF-8":.utf8,"UTF-16":.utf16,"GB18030":gb,"Big5":big5,"Windows-1252":.windowsCP1252]
      let text:String?
      if let encoding=choices[subtitleTextEncoding] { text=String(data:data,encoding:encoding) }
      else if data.starts(with:[0xff,0xfe]) || data.starts(with:[0xfe,0xff]) { text=String(data:data,encoding:.utf16) }
      else { text=String(data:data,encoding:.utf8) ?? String(data:data,encoding:gb) ?? String(data:data,encoding:big5) ?? String(data:data,encoding:.windowsCP1252) }
      guard let text else { throw URLError(.cannotDecodeContentData) }
      normalized=Data(text.utf8)
    }
    let epoch=subtitleEpoch
    let result=await Task.detached(priority:.utility) {
      normalized.withUnsafeBytes { bytes in
        fileExtension.lowercased().withCString {
          CinevaFFmpegSessionExternalSubtitle(handle.pointer,bytes.bindMemory(to:UInt8.self).baseAddress!,Int32(normalized.count),$0)
        }
      }
    }.value
    guard epoch==subtitleEpoch, self.handle === handle else { throw CancellationError() }
    guard result>=0 else { subtitleWarning="外挂字幕解析失败（\(result)）"; throw URLError(.cannotDecodeContentData) }
    subtitleWarning=nil; selectedSubtitleOptionID=nil; subtitleImage=nil
  }
  private func renderSubtitle(now: Double) {
    guard subtitleTask==nil, now-lastSubtitleRender>=0.1, let handle else { return }
    lastSubtitleRender=now
    let time=currentTime-subtitleDelay, generation=serial, epoch=subtitleEpoch
    subtitleTask=Task { @MainActor [weak self] in
      let output=await Task.detached(priority:.utility) {
        FFmpegSubtitleImages.render(handle:handle,time:time,serial:generation)
      }.value
      guard let self, self.subtitleEpoch==epoch, self.handle === handle else { return }
      self.subtitleTask=nil
      if output.changed { self.subtitleImage=output.image }
      if output.error<0 { self.subtitleWarning="字幕解码 / 队列受限（\(output.error)）；音视频继续播放" }
    }
  }
  private func fail(_ message: String) {
    // Freeze value copies before close/cancel can replace the root cause.
    if lastFailure?.session != sessionID {
      var snapshot=CinevaFFmpegSnapshot()
      if let handle { CinevaFFmpegSessionSnapshot(handle.pointer,&snapshot) }
      if let cache { mediaCacheProgress=cache.mediaCacheProgress }
      let io=cache?.statistics
      let function=withUnsafeBytes(of:snapshot.failureFunction) { String(decoding:$0.prefix { $0 != 0 },as:UTF8.self) }
      let build="\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"))"
      lastFailure=FFmpegFailureSnapshot(session:sessionID,generation:serial,backend:inputBackend,
        build:build,stage:FFmpegFailureSnapshot.stageName(snapshot.failureStage)+" / "+(function.isEmpty ? "函数不可获得" : function),
        nativeError:snapshot.errorCode,transport:io?.text ?? "原生 HTTP：传输细节不可获得；未启用未脱敏 verbose 日志",
        operations:inputBackend == .ffmpegHTTP ? "原生 HTTP 最后 read/seek 参数不可获得；AVIO position=\(snapshot.ioPosition)" : "read offset=\(snapshot.lastReadOffset) count=\(snapshot.lastReadCapacity) result=\(snapshot.lastReadResult)\n"
          + "seek offset=\(snapshot.lastSeekOffset) whence=\(snapshot.lastSeekWhence) result=\(snapshot.lastSeekResult)\n"
          + "hint=\(io?.hintedLength ?? -1) verified=\(io?.verifiedLength ?? -1) · subsequent clues=\(io?.clues.joined(separator: "; ") ?? "none")")
      diagnostics=lastFailure!.text
    }
    errorMessage=message
    audio.stop(); renderer.setPlaying(false)
    handle=nil; cache?.close(); cache=nil; ticker?.invalidate(); ticker=nil
    playbackState = .failed(message)
  }
  private func saveProgress(force: Bool = false) {
    guard !scrubbing, recordsHistory, let sourceItem, let library, duration>0 else { return }
    let second=Int(currentTime)
    if force || second/5 != savedSecond/5 {
      library.recordPlayback(sourceItem,position:currentTime,duration:duration); savedSecond=second
    }
    if force || abs(second-lastRemoteSave)>=30 {
      lastRemoteSave=second
      if let api { Task { await api.updateVideoHistory(pickCode:sourceItem.pickCode,seconds:second,watchEnd:didReachEnd) } }
    }
  }
  private func installObservers() {
    let center=NotificationCenter.default
    observers.append(center.addObserver(forName:AVAudioSession.interruptionNotification,object:nil,queue:.main) { [weak self] note in
      MainActor.assumeIsolated {
        guard let self, let raw=note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt else { return }
        if raw==AVAudioSession.InterruptionType.began.rawValue { self.interruptedIntent=self.wantsPlayback; self.pause() }
        else if self.interruptedIntent, let options=note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt,
          AVAudioSession.InterruptionOptions(rawValue:options).contains(.shouldResume) { self.resume() }
      }
    })
    observers.append(center.addObserver(forName:UIApplication.didEnterBackgroundNotification,object:nil,queue:.main) { [weak self] _ in
      MainActor.assumeIsolated { self?.cancelInteractiveScrub() }
    })
    for name in [AVAudioSession.routeChangeNotification, AVAudioSession.mediaServicesWereResetNotification, Notification.Name.AVAudioEngineConfigurationChange] {
      observers.append(center.addObserver(forName:name,object:nil,queue:.main) { [weak self] note in
        MainActor.assumeIsolated {
          guard let self else { return }
          if note.name == .AVAudioEngineConfigurationChange,
            (note.object as AnyObject?) !== self.audio.notificationObject { return }
          if note.name==AVAudioSession.mediaServicesWereResetNotification {
            self.audio.stop(); self.audio=NativeAudioRenderer()
            self.audio.setRate(self.rate); self.audio.setVolume(self.volume)
          }
          if (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt)==AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue { self.pause() }
          self.seek(to:self.currentTime)
        }
      })
    }
  }
  private func contiguousEnd(from point: Double, submitted: Double, heldStart: Double? = nil,
                             heldEnd: Double? = nil, queueStart: Double, queueEnd: Double) -> Double {
    var end=max(point,submitted)
    if let start=heldStart, let finish=heldEnd, start<=end+0.05 { end=max(end,finish) }
    if queueStart>=0, queueStart<=end+0.05 { end=max(end,queueEnd) }
    return end
  }
  private func pump() {
    guard let handle else { return }
    let now=CACurrentMediaTime()
    if scrubbing { return }
    if backgroundAudioOnly, UIApplication.shared.applicationState == .background,
      pip?.requiresVideo != true, now-lastPump<0.04 { return }
    lastPump=now
    var snapshot=CinevaFFmpegSnapshot(); CinevaFFmpegSessionSnapshot(handle.pointer,&snapshot)
    if snapshot.status<0 {
      var message=[CChar](repeating:0,count:192); CinevaFFmpegErrorText(snapshot.errorCode,&message,192)
      fail(snapshot.errorCode == -70001 ? "检测到 Dolby Vision，当前 FFmpeg 路径未实现动态元数据输出，请使用兼容内核。" : "FFmpeg \(FFmpegFailureSnapshot.stageName(snapshot.failureStage))：\(String(cString:message))（\(snapshot.errorCode)）"); return
    }
    if snapshot.serial != serial {
      resetSubtitleImage()
      toneMapTask?.cancel(); toneMapTask=nil; pendingToneMapped=false
      serial=snapshot.serial; target=snapshot.recoveryTarget
      localSeek=false
      // Native decoder fallback can legitimately advance the generation during
      // a seek. Keep its overlay until the replacement target frame arrives.
      if commitAt != nil { seekGeneration=serial } else { seekGeneration=0; seekIO=nil }
      audio.reset(to:target,generation:serial); renderer.reset(to:target,preservingImage:true); pending=nil
      waiting=true; waitStarted=now; resumeTarget=0.75
    }
    hasAudio=snapshot.audioEnabled != 0 && !audioTail
    let audioInBackground=UIApplication.shared.applicationState == .background &&
      snapshot.audioEnabled != 0 && pip?.requiresVideo != true
    if audioInBackground != backgroundAudioOnly {
      backgroundAudioOnly=audioInBackground
      CinevaFFmpegSessionSetVideoActive(handle.pointer,audioInBackground ? 0 : 1)
      toneMapTask?.cancel(); toneMapTask=nil; pendingToneMapped=false; pending=nil
      resetSubtitleImage()
      if audioInBackground { renderer.setPlaying(false) }
      else { seek(to:currentTime); return } // Rebuild video/keyframe state at the audio clock.
    }
    if snapshot.duration>0 { duration=snapshot.duration }
    for _ in 0..<12 where hasAudio && audio.queuedDuration < 0.6*Double(rate) {
      var pts=0.0, generation:Int32=0
      let count=CinevaFFmpegSessionCopyAudio(handle.pointer,&samples,65536,&pts,&generation)
      if count<=0 { break }
      _=audio.enqueue(interleaved:samples,frames:Int(count),pts:pts,generation:generation)
    }
    if !waiting {
      currentTime=max(0,hasAudio ? audio.audibleTime : renderer.time)
      CinevaFFmpegSessionSetPosition(handle.pointer,currentTime)
    }
    for _ in 0..<8 where !backgroundAudioOnly {
      if pending==nil {
        var pts=0.0, duration=0.0, generation:Int32=0
        if let pixel=CinevaFFmpegSessionCopyFrame(handle.pointer,&pts,&duration,&generation) {
          pending=(pixel,pts,duration,generation)
          pendingToneMapped=false
        }
      }
      guard let frame=pending else { break }
      if frame.3 != serial { pending=nil; continue }
      if [16,18].contains(snapshot.colorTransfer), !AVPlayer.eligibleForHDRPlayback, !pendingToneMapped {
        guard #available(iOS 18.0, *) else {
          fail("当前显示需要 HDR → SDR 映射，此系统版本转交兼容内核。"); return
        }
        if toneMapTask==nil {
          let epoch=lifecycleEpoch, mapper=toneMapper
          toneMapTask=Task { @MainActor [weak self] in
            let mapped=await Task.detached(priority:.userInitiated) { mapper.convert(frame.0) }.value
            guard let self, !Task.isCancelled, self.lifecycleEpoch==epoch,
              self.serial==frame.3, self.pending?.1==frame.1 else { return }
            self.toneMapTask=nil
            guard let mapped else { self.fail("HDR → SDR 映射无法建立可靠色彩输出，转交兼容内核。"); return }
            self.pending=(mapped,frame.1,frame.2,frame.3); self.pendingToneMapped=true; self.toneMappedSDR=true
          }
        }
        break
      }
      switch renderer.submit(frame.0,pts:frame.1,duration:frame.2,playing:wantsPlayback && !waiting,now:now) {
      case .accepted: pending=nil; if firstFrameAt==nil { firstFrameAt=now }
      case .dropped: pending=nil
      case .failed(let message): fail(message); return
      case .waiting: break
      }
      if pending != nil { break }
    }
    CinevaFFmpegSessionSnapshot(handle.pointer,&snapshot)
    guard snapshot.serial==serial else { return }
    if !waiting, !backgroundAudioOnly, renderer.waitingForData {
      // Display recovery invalidates its submitted runway: freeze audio until
      // the common buffering gate can release both outputs together.
      audio.pause(); waiting=true; waitStarted=now; resumeTarget=0.75
      playbackState = .buffering
    }
    var videoEnd=contiguousEnd(from:currentTime,submitted:renderer.lastEnd,
      heldStart:pending?.1,heldEnd:pending.map { $0.1+$0.2 },queueStart:snapshot.videoStart,queueEnd:snapshot.videoEnd)
    var audioEnd=hasAudio ? contiguousEnd(from:currentTime,submitted:audio.submittedEnd,
      queueStart:snapshot.audioStart,queueEnd:snapshot.audioEnd) : videoEnd
    if backgroundAudioOnly { videoEnd=audioEnd }
    if hasAudio, snapshot.audioDrained != 0, snapshot.pcmCount==0, audio.queuedDuration<0.015 {
      currentTime=audio.audibleTime; audio.pause(); audioTail=true; hasAudio=false
      renderer.alignClock(to:currentTime,rate:Double(rate),running:wantsPlayback && !waiting)
      audioEnd=videoEnd
    }
    if snapshot.videoDrained != 0, snapshot.frameCount==0, pending==nil, currentTime>=renderer.lastEnd { videoEnd=audioEnd }
    bufferedUntil=min(videoEnd,audioEnd) // Track intersection, never audio+video sum.
    let audioEmpty=hasAudio && audio.queuedDuration < 0.015 && snapshot.audioDrained==0
    let videoEmpty = !backgroundAudioOnly && renderer.anchored && renderer.time>renderer.lastEnd+0.15 && pending==nil && snapshot.frameCount==0 && snapshot.videoDrained==0
    if !waiting, wantsPlayback, audioEmpty || videoEmpty {
      localSeek=false
      audio.pause(); renderer.suspendForData(); waiting=true
      rebufferCount += 1; if audioEmpty { audioUnderruns += 1 }
      let ioTarget=min(4,max(2,2*max(snapshot.activeIOSeconds,snapshot.lastReadSeconds)))
      resumeTarget=max(ioTarget,min(4,2+Double(min(rebufferCount-1,2))))
      waitStarted=now; playbackState = .buffering
    }
    if waiting, wantsPlayback, backgroundAudioOnly || renderer.anchored, !hasAudio || audio.hasScheduledAudio {
      let desired=resumeTarget*Double(rate)
      let tail=snapshot.demuxEOF != 0 && bufferedDuration>0
      let capacity=snapshot.readerBackpressured != 0 && now-waitStarted>=desired && bufferedDuration>0.3
      // A local indexed seek needs a target frame and a small, scheduled PCM
      // runway. Network underrun recovery retains its existing larger runway.
      // A real disk hole/HTTP fallback immediately disables this fast path.
      let localReady=localSeek && serial==seekGeneration && cache?.mediaCacheProgress.complete == true
        && cache?.statistics.requests==seekRequests
        && (!hasAudio || audio.queuedDuration>=max(0.04,2*AVAudioSession.sharedInstance().ioBufferDuration)*Double(rate))
      if localReady || bufferedDuration>=desired || tail || capacity {
        do {
          if hasAudio { try audio.resume() }
          if !backgroundAudioOnly {
            renderer.resume(nextPTS:pending?.1,playing:true)
            renderer.alignClock(to:hasAudio ? audio.audibleTime : currentTime,rate:Double(rate),running:true)
          }
          waiting=false; playbackState = .playing
          localSeek=false
          if playbackBeganAt==nil { playbackBeganAt=now }
        } catch { fail("音频输出失败：\(error.localizedDescription)"); return }
      }
    }
    if snapshot.status==2, pending==nil, snapshot.frameCount==0, snapshot.pcmCount==0,
      (!hasAudio || audio.queuedDuration<0.02), backgroundAudioOnly || renderer.time>=renderer.lastEnd {
      pause(); playbackState = .ended; saveProgress(force:true)
    }
    if !wantsPlayback, renderer.anchored, !hasAudio || audio.hasScheduledAudio { playbackState = .paused }
    if !backgroundAudioOnly { renderSubtitle(now:now) }
    let displayReady:Bool
    if #available(iOS 17.4,*) { displayReady=renderer.layer.isReadyForDisplay }
    else { displayReady=renderer.layer.status == .rendering }
    if displayReady, renderer.anchored {
      if displayReadyAt==nil { displayReadyAt=now }
      if let began=commitAt, serial==seekGeneration, !hasAudio || audio.hasScheduledAudio,
        let submitted=renderer.anchorSubmittedAt, now-submitted>=1.0/60 {
        seekFrameMilliseconds=(now-began)*1000; commitAt=nil
        preview.display.end() // Readiness proxy, never claim physical presentation.
      }
    }
    if hasAudio, audio.playing, audio.renderedTime>target+0.01, audioRenderedAt==nil { audioRenderedAt=now }
    if serial==seekGeneration, let baseline=seekIO, let io=cache?.statistics {
      if audio.playing, audio.renderedTime>target+0.01, seekAudioMilliseconds==nil {
        seekAudioMilliseconds=(now-seekBegan)*1000
      }
      func ms(_ seconds:Double)->String { seconds>=0 ? String(format:"%.1f ms",seconds*1000) : "等待" }
      seekDiagnostic="seek generation=\(serial) · 媒体 HTTP=\(io.requests-baseline.requests) · refresh=\(io.refreshes-baseline.refreshes)"
        + " · 内存命中=\(io.memoryHitBytes-baseline.memoryHitBytes) B · 磁盘命中=\(io.diskHitBytes-baseline.diskHitBytes) B"
        + " · 磁盘读取=\(io.diskReads-baseline.diskReads) 次/\(ms(io.diskReadSeconds-baseline.diskReadSeconds))"
        + " · 关键帧定位=\(ms(snapshot.seekLookupSeconds)) · 解码预滚至目标帧=\(ms(snapshot.seekPrerollSeconds))"
        + " · 目标帧就绪=\(seekFrameMilliseconds.map { ms($0/1000) } ?? "等待")"
        + " · 音频 render 恢复=\(hasAudio ? (seekAudioMilliseconds.map { ms($0/1000) } ?? (wantsPlayback ? "等待" : "保持暂停")) : "无音轨")"
      if seekFrameMilliseconds != nil, !hasAudio || !wantsPlayback || seekAudioMilliseconds != nil {
        NSLog("Cineva %@",seekDiagnostic); seekIO=nil
      }
    }
    if !isPlaying { uninterruptedAt=nil } else if uninterruptedAt==nil { uninterruptedAt=now }
    if isPlaying, let began=uninterruptedAt, now-began>=1, !hasAudio || audioRenderedAt != nil,
      displayReadyAt != nil, stableAt==nil { stableAt=now }

    // Playback gating always uses decoded A/V continuity. UI only uses durable
    // file coverage, coalesced independently of packet -> frame/PCM handoffs.
    cache?.allowPrefetch(!scrubbing && ((!waiting && bufferedDuration>=2 && stableAt != nil)
      || (!wantsPlayback && renderer.anchored && playbackState != .seeking)))
    if now-lastPublished>=0.2 {
      lastPublished=now
      if hasAudio, !waiting, wantsPlayback, !backgroundAudioOnly { renderer.disciplineClock(to:audio.audibleTime,rate:Double(rate)) }
      rotation=snapshot.rotation; videoSize=CGSize(width:Int(snapshot.width),height:Int(snapshot.height))
      pip?.update()
      var tracks:[PlayerTrack]=[]
      for ordinal in 0..<CinevaFFmpegSessionAudioTrackCount(handle.pointer) {
        var track=CinevaFFmpegAudioTrack()
        if CinevaFFmpegSessionAudioTrack(handle.pointer,ordinal,&track)==0 { continue }
        let language=withUnsafeBytes(of:track.language) { String(decoding:$0.prefix { $0 != 0 },as:UTF8.self) }
        let title=withUnsafeBytes(of:track.title) { String(decoding:$0.prefix { $0 != 0 },as:UTF8.self) }
        tracks.append(PlayerTrack(id:String(track.index),title:"\(title.isEmpty ? language : title) · \(track.channels)ch · \(String(cString:CinevaFFmpegCodecName(track.codec)))",kind:.audio,language:language))
      }
      audioTracks=tracks; selectedAudioOptionID=String(snapshot.selectedAudioIndex)
      if defaultAudioID==nil, snapshot.selectedAudioIndex>=0 { defaultAudioID=selectedAudioOptionID }
      var subtitles:[PlayerTrack]=[]
      for ordinal in 0..<CinevaFFmpegSessionSubtitleTrackCount(handle.pointer) {
        var track=CinevaFFmpegSubtitleTrack()
        if CinevaFFmpegSessionSubtitleTrack(handle.pointer,ordinal,&track)==0 { continue }
        let language=withUnsafeBytes(of:track.language) { String(decoding:$0.prefix { $0 != 0 },as:UTF8.self) }
        let title=withUnsafeBytes(of:track.title) { String(decoding:$0.prefix { $0 != 0 },as:UTF8.self) }
        subtitles.append(PlayerTrack(id:String(track.index),title:"\(title.isEmpty ? language : title) · \(String(cString:CinevaFFmpegCodecName(track.codec)))",kind:.subtitle,language:language))
      }
      subtitleTracks=subtitles
      if !restoredAudioPreference, recordsHistory, snapshot.status==1, hasAudio, !tracks.isEmpty, let key=audioPreferenceKey {
        restoredAudioPreference=true
        if let saved=UserDefaults.standard.string(forKey:key), saved != selectedAudioOptionID,
          tracks.contains(where: { $0.id==saved }) { selectAudio(saved); return }
      }
      if let cache { mediaCacheProgress=cache.mediaCacheProgress }
      let io=cache?.statistics
      hasAtmosMetadata=snapshot.atmosMetadataDetected != 0
      let bytes=io?.networkBytes ?? 0
      let speed=now>lastNetworkAt ? Double(bytes-lastNetworkBytes)*8/(now-lastNetworkAt)/1_000_000 : 0
      lastNetworkAt=now; lastNetworkBytes=bytes
      statistics=PlayerStatistics(backend:.ffmpeg,codec:String(cString:CinevaFFmpegCodecName(snapshot.videoCodec)),
        videoSize:videoSize,fps:snapshot.fps,hdrFormat:snapshot.colorTransfer==16 ? "PQ 标记" : snapshot.colorTransfer==18 ? "HLG 标记" : "SDR",
        networkMbps:io == nil ? nil : speed,downloadedBytes:io?.networkBytes,bufferedSeconds:bufferedDuration,
        cachedBytes:mediaCacheProgress.bytes,decoder:snapshot.decoderType==2 ? "VideoToolbox" : "FFmpeg 软件解码",
        renderer:"Apple Native + AVAudioEngine PCM",droppedFrames:renderer.droppedFrames,
        avSyncOffset:hasAudio ? renderer.time-audio.audibleTime : nil)
      func elapsed(_ time:Double?) -> String { time.map { String(format:"%.3f s",$0-clickAt) } ?? "尚未发生 / 不可获得" }
      let displayStage:String
      if #available(iOS 17.4,*) { displayStage="显示就绪代理" } else { displayStage="已提交/渲染状态代理（iOS 17.4 前）" }
      let stages="session=\(sessionID.uuidString) · 播放请求→地址 \(elapsed(sourceResolvedAt)) · 首有效字节 \(snapshot.firstByteSeconds>0 ? elapsed(startAt+snapshot.firstByteSeconds) : "原生 HTTP 不可获得")\n"
        + "容器打开 \(snapshot.openSeconds>0 ? elapsed(startAt+snapshot.openSeconds) : "尚未发生") · 流信息 \(snapshot.probeSeconds>0 ? elapsed(startAt+snapshot.probeSeconds) : "尚未发生")\n"
        + "首解码 \(snapshot.firstDecodedSeconds>0 ? elapsed(startAt+snapshot.firstDecodedSeconds) : "尚未发生") · 首提交 \(elapsed(firstFrameAt)) · \(displayStage) \(elapsed(displayReadyAt))（非屏幕呈现测量）\n"
        + "音频 render 时钟开始 \(elapsed(audioRenderedAt))（非实际扬声器首声测量） · 连续运行 1 秒代理 \(elapsed(stableAt))\n"
        + "拖动最终 seek \(finalSeekCount) 次 · 松手→目标帧就绪代理 \(seekFrameMilliseconds.map { String(format:"%.1f ms",$0) } ?? "尚未发生")\n\(preview.diagnostic)\n"
      var usage=rusage(); getrusage(RUSAGE_SELF,&usage)
      let cpu=Double(usage.ru_utime.tv_sec+usage.ru_stime.tv_sec)+Double(usage.ru_utime.tv_usec+usage.ru_stime.tv_usec)/1_000_000
      let percent=usageAt>0 ? max(0,(cpu-cpuSeconds)/(now-usageAt)*100) : 0
      cpuSeconds=cpu; usageAt=now
      let resources=String(format:"App 峰值 RSS %.1f MiB · 区间 CPU %.1f%%（单核=100%%，含整个进程）\n",Double(usage.ru_maxrss)/1048576,percent)
      diagnostics=stages+seekDiagnostic+"\n"+resources+"FFmpeg · \(inputBackend.rawValue) · \(playbackState.title)\n"
        + "色彩：\(statistics.hdrFormat ?? "未知") · 系统 HDR 资格 \(AVPlayer.eligibleForHDRPlayback ? "有" : "无") · 已请求 EDR；实际屏幕输出待设备确认\n"
        + "SDR 映射：\(toneMappedSDR ? "Core Image Reference White → sRGB" : "未启用；原生像素路径")\n"
        + "当前音轨：\(String(cString:CinevaFFmpegCodecName(snapshot.audioCodec))) · 切轨警告 \(snapshot.audioWarningCode) · 输出 PCM 非 Atmos\n"
        + "Atmos 元数据：\(hasAtmosMetadata ? "解码器已识别" : "尚未识别；不据 EAC3 名称推断") · 输出能力由系统格式和路由决定\n"
        + String(format:"主时钟 %.3f · 音频 decoded %.3f / submitted %.3f / rendered %.3f / audible估算 %.3f\n",currentTime,snapshot.audioDecodedTime,audio.submittedEnd,audio.renderedTime,audio.audibleTime)
        + String(format:"A/V偏差估算 %.3f s · A连续 %.2f / V连续 %.2f s · 恢复 %.2f s\n",renderer.time-audio.audibleTime,max(0,audioEnd-currentTime),max(0,videoEnd-currentTime),resumeTarget)
        + "音频欠载 \(audioUnderruns) · rebuffer \(rebufferCount) · AAC/其他音轨 → Swr → Float32 48kHz stereo PCM（非 Atmos）\n"
        + "AVIO bytes \(snapshot.ioBytesRead) · packet jumps \(snapshot.backwardPacketJumps)/\(snapshot.largeForwardPacketJumps)（不是 HTTP 请求）\n"
        + (io.map { "HTTP requests \($0.requests) · 200/206/416 \($0.responses200)/\($0.responses206)/\($0.responses416) · 网络 bytes \($0.networkBytes)\n内存命中字节 \($0.memoryHitBytes) · 磁盘命中字节 \($0.diskHitBytes) · miss \($0.misses) · refresh \($0.refreshes)\n\($0.lastError ?? "")\n\($0.recoveryText)" } ?? "HTTP 请求数不可获得")
      saveProgress()
    }
  }
}

/// Only unsupported-HDR displays enter this bounded GPU path. Eligible HDR
/// continues directly from VideoToolbox to the native sample-buffer layer.
private final class FFmpegSDRToneMapper: @unchecked Sendable {
  private let queue=DispatchQueue(label:"cineva.tonemap",qos:.userInitiated)
  private let context=CIContext(options:[.cacheIntermediates:false,
    .workingColorSpace:CGColorSpace(name:CGColorSpace.extendedLinearSRGB)!])
  private let outputSpace=CGColorSpace(name:CGColorSpace.sRGB)!
  private var pool: CVPixelBufferPool?
  private var width=0, height=0
  func reset() { queue.async { self.pool=nil; self.context.clearCaches() } }
  @available(iOS 18.0, *)
  func convert(_ source: CVPixelBuffer) -> CVPixelBuffer? {
    queue.sync {
      let image=CIImage(cvPixelBuffer:source)
      // Unknown source headroom is not permission to guess a tone curve.
      guard image.contentHeadroom>1, let filter=CIFilter(name:"CIToneMapHeadroom") else { return nil }
      filter.setValue(image,forKey:kCIInputImageKey)
      filter.setValue(1.0,forKey:"inputTargetHeadroom")
      guard let mapped=filter.outputImage else { return nil }
      let w=CVPixelBufferGetWidth(source),h=CVPixelBufferGetHeight(source)
      if pool==nil || width != w || height != h {
        width=w; height=h
        let attributes:[String:Any]=[kCVPixelBufferWidthKey as String:w,kCVPixelBufferHeightKey as String:h,
          kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA,
          kCVPixelBufferIOSurfacePropertiesKey as String:[:],kCVPixelBufferMetalCompatibilityKey as String:true]
        guard CVPixelBufferPoolCreate(nil,nil,attributes as CFDictionary,&pool)==kCVReturnSuccess else { return nil }
      }
      guard let pool else { return nil }
      var pixel:CVPixelBuffer?
      let budget=[kCVPixelBufferPoolAllocationThresholdKey as String:4] as CFDictionary
      guard CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil,pool,budget,&pixel)==kCVReturnSuccess,let pixel else { return nil }
      context.render(mapped,to:pixel,bounds:image.extent,colorSpace:outputSpace)
      CVBufferSetAttachment(pixel,kCVImageBufferCGColorSpaceKey,outputSpace,.shouldPropagate)
      CVBufferSetAttachment(pixel,kCVImageBufferColorPrimariesKey,kCVImageBufferColorPrimaries_ITU_R_709_2,.shouldPropagate)
      CVBufferSetAttachment(pixel,kCVImageBufferTransferFunctionKey,kCVImageBufferTransferFunction_sRGB,.shouldPropagate)
      return pixel
    }
  }
}

private enum FFmpegSubtitleImages {
  struct Result: @unchecked Sendable { let changed: Bool; let image: UIImage?; let error: Int32 }
  static let context=CIContext(options:[.cacheIntermediates:false])
  static func render(handle:FFmpegSessionHandle,time:Double,serial:Int32) -> Result {
    var changed:Int32=0
    let pixel=CinevaFFmpegSessionCopySubtitle(handle.pointer,time,serial,&changed)
    let error=CinevaFFmpegSessionSubtitleError(handle.pointer)
    guard let pixel else { return Result(changed:changed != 0,image:nil,error:error) }
    let source=CIImage(cvPixelBuffer:pixel)
    let image=context.createCGImage(source,from:source.extent).map { UIImage(cgImage:$0) }
    return Result(changed:changed != 0,image:image,error:error)
  }
}
