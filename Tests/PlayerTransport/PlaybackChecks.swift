import Foundation

@main struct PlaybackChecks {
  static func main() {
    var checks=0
    func expect(_ ok:Bool,_ name:String) { precondition(ok,name); checks+=1 }
    let suite="cineva-test-"+UUID().uuidString
    let defaults=UserDefaults(suiteName:suite)!
    defer { defaults.removePersistentDomain(forName:suite) }
    for old in ["automatic","system","vlc","mpv",""] {
      defaults.set(old,forKey:"cineva.playback.originalEngine.v1")
      defaults.set(1.5,forKey:"rate"); defaults.set("original",forKey:"quality"); defaults.set("keep",forKey:"history")
      PlaybackPolicy.migrateEnginePreference(defaults)
      expect(defaults.string(forKey:"cineva.playback.originalEngine.v1")==nil,"Retired preference removed")
      expect(defaults.double(forKey:"rate")==1.5 && defaults.string(forKey:"quality")=="original" && defaults.string(forKey:"history")=="keep","Unrelated preferences preserved")
      let original=VideoSource(id:"x",title:"",definition:0,url:URL(string:"https://example.invalid/video.mp4")!,kind:.original,headers:[:])
      expect(PlaybackPolicy.input(for:original) == .customAVIOStreaming,"Original always begins with FFmpeg streaming")
      PlaybackPolicy.migrateEnginePreference(defaults)
      expect(PlaybackPolicy.input(for:original) == .customAVIOStreaming,"Restart/next-item policy is independent of legacy preference")
    }
    for kind in [VideoSource.Kind.original,.transcoded] {
      let hls=VideoSource(id:"hls",title:"",definition:1,url:URL(string:"https://example.invalid/master.m3u8")!,kind:kind,headers:[:])
      expect(PlaybackPolicy.input(for:hls) == .ffmpegHTTP,"HLS never enters fixed-byte cache")
    }
    for (value,expected) in [(0.0,"00:00.000"),(-1,"00:00.000"),(Double.nan,"00:00.000"),(.infinity,"00:00.000"),(12.345,"00:12.345"),(59.9996,"01:00.000"),(3599.9996,"01:00:00.000"),(3723.456,"01:02:03.456")] {
      expect(PlaybackPolicy.timestamp(value)==expected,"Millisecond rounding/carry/invalid values")
    }
    print("Playback policy checks passed: \(checks)")
  }
}
