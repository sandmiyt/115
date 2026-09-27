import AVFoundation

/// Owns scheduled PCM through AVAudioPlayerNode. Its audio callbacks do no I/O,
/// allocation, resampling, waiting or actor hops. Control/polling runs on MainActor.
@MainActor
final class NativeAudioRenderer {
  private let engine = AVAudioEngine()
  private let node = AVAudioPlayerNode()
  private let pitch = AVAudioUnitTimePitch()
  private let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
  private var anchor: Double?
  private var heldTime = 0.0
  private(set) var submittedEnd = 0.0
  private(set) var renderedTime = 0.0
  private(set) var playing = false
  private(set) var rate: Float = 1
  private(set) var volume: Float = 1
  private(set) var generation: Int32 = 1
  var latency: Double { max(AVAudioSession.sharedInstance().outputLatency,engine.outputNode.presentationLatency) + pitch.latency + AVAudioSession.sharedInstance().ioBufferDuration }
  var audibleTime: Double {
    guard playing, let anchor, let nodeTime = node.lastRenderTime,
      let playerTime = node.playerTime(forNodeTime: nodeTime), playerTime.isSampleTimeValid else { return heldTime }
    let rendered = anchor + Double(playerTime.sampleTime)/playerTime.sampleRate
    renderedTime = min(submittedEnd, max(anchor,rendered))
    return min(submittedEnd, max(anchor, rendered - latency*Double(rate)))
  }
  var queuedDuration: Double { max(0,submittedEnd-audibleTime) }
  var hasScheduledAudio: Bool { anchor != nil }

  init() {
    engine.attach(node); engine.attach(pitch)
    engine.connect(node,to:pitch,format:format)
    engine.connect(pitch,to:engine.mainMixerNode,format:format)
    pitch.pitch = 0; pitch.rate = 1
  }
  func prepare() throws {
    let session = AVAudioSession.sharedInstance()
    try session.setCategory(.playback,mode:.moviePlayback,options:[.allowAirPlay,.allowBluetoothA2DP])
    try session.setActive(true)
    if !engine.isRunning { try engine.start() }
  }
  func reset(to time: Double, generation: Int32) {
    node.stop() // Unschedules every old-generation buffer, including TimePitch input.
    pitch.reset()
    self.generation=generation; anchor=nil; heldTime=time; submittedEnd=time; renderedTime=time; playing=false
  }
  func stop() { node.stop(); engine.stop(); playing=false; anchor=nil }
  func pause() { heldTime=audibleTime; node.pause(); playing=false }
  func resume() throws {
    try prepare()
    guard anchor != nil else { return }
    node.play(); playing=true
  }
  func setRate(_ value: Float) { rate=min(2,max(0.5,value)); pitch.rate=rate }
  func setVolume(_ value: Float) { volume=min(1,max(0,value)); node.volume=volume }
  func enqueue(interleaved: [Float], frames: Int, pts: Double, generation: Int32) -> Bool {
    guard generation==self.generation, frames>0, pts.isFinite,
      let buffer=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:AVAudioFrameCount(frames)),
      let channels=buffer.floatChannelData else { return false }
    // Swr has already normalized layout and mixed all input channels to stereo.
    // This is only a representation copy, never "take the first two channels".
    for i in 0..<frames { channels[0][i]=interleaved[2*i]; channels[1][i]=interleaved[2*i+1] }
    buffer.frameLength=AVAudioFrameCount(frames)
    if anchor==nil { anchor=pts; heldTime=pts }
    node.scheduleBuffer(buffer,completionHandler:nil)
    submittedEnd=pts+Double(frames)/48000
    return true
  }
}
