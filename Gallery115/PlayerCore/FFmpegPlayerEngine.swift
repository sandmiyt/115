import AVFoundation
import CinevaFFmpeg
import CryptoKit
import Observation
import UIKit

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
  private(set) var trial = FFmpegDiagnosticTrial(mode:.cachedAudio,position:0,hardware:true)
  @ObservationIgnored private var trialPlaybackAt: Double?
  @ObservationIgnored private var trialFrozen = false
  private(set) var errorMessage: String?
  private(set) var videoSize: CGSize?
  private(set) var rotation = 0.0
  private(set) var audioUnderruns = 0
  private(set) var rebufferCount = 0
  private(set) var audioTracks: [PlayerTrack] = []
  var subtitleTracks: [PlayerTrack] { [] } // Embedded subtitle capability is reported separately until implemented.
  private(set) var selectedAudioOptionID: String?
  var selectedSubtitleOptionID: String? { nil }
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
    return PlayerLoadingFeedback(delayMilliseconds:350,generation:Int(serial))
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
  @ObservationIgnored private var scrubTask: Task<Void,Never>?
  @ObservationIgnored private var audioTail = false
  @ObservationIgnored private var restoredAudioPreference = false
  @ObservationIgnored private var recordsHistory = true

  func start(source: VideoSource, item: CloudItem, api: APIClient, library: LibraryStore,
             at position: Double, playing: Bool = true, useCache: Bool = true, preferHardware: Bool = true,
             recordsHistory: Bool = true) {
    stop()
    self.recordsHistory=recordsHistory
    currentSource=source; sourceItem=item; self.api=api; self.library=library
    target=max(0,position.isFinite ? position : 0); currentTime=target
    trial=FFmpegDiagnosticTrial(mode:useCache ? .cachedAudio : .standard,position:target,hardware:preferHardware)
    trialPlaybackAt=nil; trialFrozen=false
    wantsPlayback=playing; waiting=true; resumeTarget=0.75; serial=1
    rebufferCount=0; audioUnderruns=0; firstFrameAt=nil
    audioTracks=[]; selectedAudioOptionID=nil; audioTail=false; restoredAudioPreference=false
    errorMessage=nil; startAt=CACurrentMediaTime(); waitStarted=startAt
    lastPublished=0; lastNetworkAt=startAt; lastNetworkBytes=0
    duration=item.duration; playbackState = .preparing
    renderer.reset(to:target,newSession:true); audio.reset(to:target,generation:serial)
    guard source.isOriginal else { fail("FFmpeg 分段缓存目前要求原文件；转码清单请使用兼容内核。"); return }
    guard source.headers.allSatisfy({ !$0.key.contains(where: \.isNewline) && !$0.value.contains(where: \.isNewline) && !$0.key.contains(":") }) else {
      fail("媒体请求头格式无效"); return
    }
    var options = CinevaFFmpegSessionOptions()
    options.preferHardware=preferHardware ? 1 : 0; options.videoOnly=0; options.outputAudio=1
    if useCache {
      let scope: String
      if MediaSourceSelectionStore.shared.resolvedSource == .cloud115 {
        // Account API has no stable user identifier in the current auth model.
        // Hash the authenticated session, sacrificing reuse after rotation rather
        // than sharing cached private bytes between accounts.
        let token=Cloud115SessionStore.shared.session?.refreshToken ?? UUID().uuidString
        scope="115-session:"+SHA256.hash(data:Data(token.utf8)).map { String(format:"%02x",$0) }.joined()
      } else { scope=ThumbnailService.currentNamespace() }
      let identity=RangeCacheIdentity(account:scope,fileID:item.id,size:item.size,
        validator:item.sha1.isEmpty ? "" : "sha1:"+item.sha1.lowercased())
      let coordinator=RangeCoordinator(source:source,identity:identity,refresh:{
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
    audio.setRate(rate); audio.setVolume(volume)
    installObservers()
    let timer=Timer(timeInterval:1.0/60,repeats:true) { [weak self] _ in
      MainActor.assumeIsolated { self?.pump() }
    }
    RunLoop.main.add(timer,forMode:.common); ticker=timer
  }
  func stop() {
    interruptTrial("提前停止 / 切换模式")
    pip?.stop()
    scrubTask?.cancel(); scrubTask=nil
    saveProgress(force:true)
    ticker?.invalidate(); ticker=nil
    audio.stop(); renderer.reset(to:currentTime); pending=nil
    handle=nil; cache?.close(); cache=nil
    observers.forEach(NotificationCenter.default.removeObserver); observers.removeAll()
    playbackState = .stopped
  }
  func pause() {
    interruptTrial("暂停或播放结束，观察窗口未完成")
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
  func setPlaybackRate(_ value: Float) {
    rate=min(2,max(0.5,value)); audio.setRate(rate)
    renderer.alignClock(to:currentTime,rate:Double(rate),running:isPlaying)
  }
  func setVolume(_ value: Float) { volume=min(1,max(0,value)); audio.setVolume(volume) }
  func seek(to seconds: Double) {
    interruptTrial("含手动定位，观察窗口未完成")
    guard let handle, seconds.isFinite else { return }
    target=min(max(0,seconds),duration>0 ? max(0,duration-0.01) : max(0,seconds))
    // Stop already scheduled old audio before publishing a new generation.
    audio.pause(); renderer.setPlaying(false)
    serial=CinevaFFmpegSessionSeek(handle.pointer,target)
    audio.reset(to:target,generation:serial); renderer.reset(to:target)
    pending=nil; currentTime=target; waiting=true; resumeTarget=0.75
    audioTail=false
    waitStarted=CACurrentMediaTime(); playbackState = .seeking
  }
  func replayFromStart() { wantsPlayback=true; seek(to:0) }
  func beginInteractiveScrub() -> Bool { let intent=wantsPlayback; pause(); isInteractiveScrubLoading=true; return intent }
  func interactiveScrub(to seconds: Double) {
    scrubTask?.cancel()
    scrubTask=Task { @MainActor [weak self] in
      do { try await Task.sleep(for:.milliseconds(120)) } catch { return }
      self?.seek(to:seconds)
    }
  }
  func endInteractiveScrub(to seconds: Double, resumeAfter: Bool) {
    wantsPlayback=resumeAfter; isInteractiveScrubLoading=false; seek(to:seconds)
    scrubTask?.cancel(); scrubTask=nil
  }
  func selectAudio(_ id: String?) {
    interruptTrial("切换音轨，观察窗口未完成")
    guard let id, let index=Int32(id), let handle else { return }
    audio.pause(); renderer.setPlaying(false)
    let next=CinevaFFmpegSessionSelectAudio(handle.pointer,index)
    guard next>0 else { if wantsPlayback { resume() }; return }
    serial=next; target=currentTime; audio.reset(to:target,generation:next); renderer.reset(to:target)
    pending=nil; waiting=true; resumeTarget=0.75; waitStarted=CACurrentMediaTime(); audioTail=false
    playbackState = .seeking
    if let item=sourceItem {
      UserDefaults.standard.set(id,forKey:"cineva.ffmpeg.audio."+item.id)
    }
  }
  func selectSubtitle(_ id: String?) {
    // Normal-screen sidecar selection is already owned by PlayerScreen. Never
    // claim an embedded track was selected when no subtitle decoder owns it.
    if id != nil { errorMessage="此内封字幕尚未接入 FFmpeg；请选择兼容内核。" }
  }
  private func fail(_ message: String) {
    interruptTrial("播放失败，观察窗口未完成")
    errorMessage=message
    audio.stop(); renderer.setPlaying(false)
    handle=nil; cache?.close(); cache=nil; ticker?.invalidate(); ticker=nil
    playbackState = .failed(message)
  }
  private func interruptTrial(_ reason: String) {
    if !trialFrozen { trial.interruption=reason; trialFrozen=true }
  }
  private func saveProgress(force: Bool = false) {
    guard recordsHistory, let sourceItem, let library, duration>0 else { return }
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
    for name in [AVAudioSession.routeChangeNotification, AVAudioSession.mediaServicesWereResetNotification] {
      observers.append(center.addObserver(forName:name,object:nil,queue:.main) { [weak self] note in
        MainActor.assumeIsolated {
          guard let self else { return }
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
    var snapshot=CinevaFFmpegSnapshot(); CinevaFFmpegSessionSnapshot(handle.pointer,&snapshot)
    if snapshot.status<0 {
      var message=[CChar](repeating:0,count:192); CinevaFFmpegErrorText(snapshot.errorCode,&message,192)
      fail(snapshot.errorCode == -70001 ? "检测到 Dolby Vision，当前 FFmpeg 路径未实现动态元数据输出，请使用兼容内核。" : "FFmpeg 阶段 \(snapshot.failureStage)：\(String(cString:message))（\(snapshot.errorCode)）"); return
    }
    if snapshot.serial != serial {
      serial=snapshot.serial; target=snapshot.recoveryTarget
      audio.reset(to:target,generation:serial); renderer.reset(to:target); pending=nil
      waiting=true; waitStarted=now; resumeTarget=0.75
    }
    hasAudio=snapshot.audioEnabled != 0 && !audioTail
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
    for _ in 0..<8 {
      if pending==nil {
        var pts=0.0, duration=0.0, generation:Int32=0
        if let pixel=CinevaFFmpegSessionCopyFrame(handle.pointer,&pts,&duration,&generation) {
          pending=(pixel,pts,duration,generation)
        }
      }
      guard let frame=pending else { break }
      if frame.3 != serial { pending=nil; continue }
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
    if !waiting, renderer.waitingForData {
      // Display recovery invalidates its submitted runway: freeze audio until
      // the common buffering gate can release both outputs together.
      audio.pause(); waiting=true; waitStarted=now; resumeTarget=0.75
      playbackState = .buffering
    }
    var videoEnd=contiguousEnd(from:currentTime,submitted:renderer.lastEnd,
      heldStart:pending?.1,heldEnd:pending.map { $0.1+$0.2 },queueStart:snapshot.videoStart,queueEnd:snapshot.videoEnd)
    var audioEnd=hasAudio ? contiguousEnd(from:currentTime,submitted:audio.submittedEnd,
      queueStart:snapshot.audioStart,queueEnd:snapshot.audioEnd) : videoEnd
    if hasAudio, snapshot.audioDrained != 0, snapshot.pcmCount==0, audio.queuedDuration<0.015 {
      currentTime=audio.audibleTime; audio.pause(); audioTail=true; hasAudio=false
      renderer.alignClock(to:currentTime,rate:Double(rate),running:wantsPlayback && !waiting)
      audioEnd=videoEnd
    }
    if snapshot.videoDrained != 0, snapshot.frameCount==0, pending==nil, currentTime>=renderer.lastEnd { videoEnd=audioEnd }
    bufferedUntil=min(videoEnd,audioEnd) // Track intersection, never audio+video sum.
    let audioEmpty=hasAudio && audio.queuedDuration < 0.015 && snapshot.audioDrained==0
    let videoEmpty=renderer.anchored && renderer.time>renderer.lastEnd+0.15 && pending==nil && snapshot.frameCount==0 && snapshot.videoDrained==0
    if !waiting, wantsPlayback, audioEmpty || videoEmpty {
      audio.pause(); renderer.suspendForData(); waiting=true
      rebufferCount += 1; if audioEmpty { audioUnderruns += 1 }
      resumeTarget=min(4,2+Double(min(rebufferCount-1,2)))
      waitStarted=now; playbackState = .buffering
    }
    if waiting, wantsPlayback, renderer.anchored, !hasAudio || audio.hasScheduledAudio {
      let desired=resumeTarget*Double(rate)
      let tail=snapshot.demuxEOF != 0 && bufferedDuration>0
      let capacity=snapshot.readerBackpressured != 0 && now-waitStarted>=desired && bufferedDuration>0.3
      if bufferedDuration>=desired || tail || capacity {
        do {
          if hasAudio { try audio.resume() }
          renderer.resume(nextPTS:pending?.1,playing:true)
          renderer.alignClock(to:hasAudio ? audio.audibleTime : currentTime,rate:Double(rate),running:true)
          waiting=false; playbackState = .playing
          if trialPlaybackAt==nil { trialPlaybackAt=now }
        } catch { fail("音频输出失败：\(error.localizedDescription)"); return }
      }
    }
    if snapshot.status==2, pending==nil, snapshot.frameCount==0, snapshot.pcmCount==0,
      (!hasAudio || audio.queuedDuration<0.02), renderer.time>=renderer.lastEnd {
      pause(); playbackState = .ended; saveProgress(force:true)
    }
    if !wantsPlayback, firstFrameAt != nil { playbackState = .paused }
    if now-lastPublished>=0.25 {
      lastPublished=now
      if hasAudio, !waiting, wantsPlayback { renderer.disciplineClock(to:audio.audibleTime,rate:Double(rate)) }
      rotation=snapshot.rotation; videoSize=CGSize(width:Int(snapshot.width),height:Int(snapshot.height))
      pip?.update()
      if [16,18].contains(snapshot.colorTransfer), !AVPlayer.eligibleForHDRPlayback {
        fail("媒体标记为 HDR，当前显示路径不具备 HDR 资格且尚未实现色调映射，转交兼容内核。"); return
      }
      var tracks:[PlayerTrack]=[]
      for ordinal in 0..<CinevaFFmpegSessionAudioTrackCount(handle.pointer) {
        var track=CinevaFFmpegAudioTrack()
        if CinevaFFmpegSessionAudioTrack(handle.pointer,ordinal,&track)==0 { continue }
        let language=withUnsafeBytes(of:track.language) { String(decoding:$0.prefix { $0 != 0 },as:UTF8.self) }
        let title=withUnsafeBytes(of:track.title) { String(decoding:$0.prefix { $0 != 0 },as:UTF8.self) }
        tracks.append(PlayerTrack(id:String(track.index),title:"\(title.isEmpty ? language : title) · \(track.channels)ch · \(String(cString:CinevaFFmpegCodecName(track.codec)))",kind:.audio,language:language))
      }
      audioTracks=tracks; selectedAudioOptionID=String(snapshot.selectedAudioIndex)
      if !restoredAudioPreference, snapshot.status==1, hasAudio, !tracks.isEmpty, let item=sourceItem {
        restoredAudioPreference=true
        if let saved=UserDefaults.standard.string(forKey:"cineva.ffmpeg.audio."+item.id), saved != selectedAudioOptionID,
          tracks.contains(where: { $0.id==saved }) { selectAudio(saved); return }
      }
      let io=cache?.statistics
      if !trialFrozen {
        trial.firstFrame=firstFrameAt.map { $0-startAt }
        trial.firstPlayback=trialPlaybackAt.map { $0-startAt }
        trial.elapsed=trialPlaybackAt.map { min(10,now-$0) } ?? 0
        trial.stalls=rebufferCount; trial.bytes=snapshot.ioBytesRead
        trial.backwards=Int(snapshot.backwardPacketJumps); trial.forwards=Int(snapshot.largeForwardPacketJumps)
        trial.averageRead=snapshot.averageReadFrameDuration; trial.maximumRead=snapshot.maximumReadFrameDuration
        trial.compressed=snapshot.queuedSeconds; trial.httpRequests=io?.requests; trial.networkBytes=io?.networkBytes
        trial.cacheHitBytes=io.map { $0.memoryHitBytes+$0.diskHitBytes }
        if trial.elapsed>=10 { trial.complete=true; trialFrozen=true }
      }
      let bytes=io?.networkBytes ?? 0
      let speed=now>lastNetworkAt ? Double(bytes-lastNetworkBytes)*8/(now-lastNetworkAt)/1_000_000 : 0
      lastNetworkAt=now; lastNetworkBytes=bytes
      statistics=PlayerStatistics(backend:.ffmpeg,codec:String(cString:CinevaFFmpegCodecName(snapshot.videoCodec)),
        videoSize:videoSize,fps:snapshot.fps,hdrFormat:snapshot.colorTransfer==16 ? "PQ 标记" : snapshot.colorTransfer==18 ? "HLG 标记" : "SDR",
        networkMbps:io == nil ? nil : speed,downloadedBytes:io?.networkBytes,bufferedSeconds:bufferedDuration,
        cachedBytes:io.map { Int64($0.memoryBytes) },decoder:snapshot.decoderType==2 ? "VideoToolbox" : "FFmpeg 软件解码",
        renderer:"Apple Native + AVAudioEngine PCM",droppedFrames:renderer.droppedFrames,
        avSyncOffset:hasAudio ? renderer.time-audio.audibleTime : nil)
      diagnostics="FFmpeg · \(cache == nil ? "旧 HTTP" : "Custom AVIO / 分段缓存") · \(playbackState.title)\n"
        + String(format:"主时钟 %.3f · 音频 decoded %.3f / submitted %.3f / rendered %.3f / audible估算 %.3f\n",currentTime,snapshot.audioDecodedTime,audio.submittedEnd,audio.renderedTime,audio.audibleTime)
        + String(format:"A/V偏差估算 %.3f s · A连续 %.2f / V连续 %.2f s · 恢复 %.2f s\n",renderer.time-audio.audibleTime,max(0,audioEnd-currentTime),max(0,videoEnd-currentTime),resumeTarget)
        + "音频欠载 \(audioUnderruns) · rebuffer \(rebufferCount) · AAC/其他音轨 → Swr → Float32 48kHz stereo PCM（非 Atmos）\n"
        + "AVIO bytes \(snapshot.ioBytesRead) · packet jumps \(snapshot.backwardPacketJumps)/\(snapshot.largeForwardPacketJumps)（不是 HTTP 请求）\n"
        + (io.map { "HTTP requests \($0.requests) · 200/206/416 \($0.responses200)/\($0.responses206)/\($0.responses416) · 网络 bytes \($0.networkBytes)\n内存命中字节 \($0.memoryHitBytes) · 磁盘命中字节 \($0.diskHitBytes) · miss \($0.misses) · refresh \($0.refreshes)\n\($0.lastError ?? "")" } ?? "HTTP 请求数不可获得")
      saveProgress()
    }
  }
}
