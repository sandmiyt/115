platform :ios, '17.0'
use_frameworks!

target 'Gallery115' do
  # Build the pinned, symbol-isolated XCFramework with Dependencies/FFmpeg/build-apple.sh first.
  pod 'CinevaFFmpeg', :path => 'Dependencies/FFmpeg'
  # Required fallback engine for MKV / AVI / TS / WebM / ISO and originals
  # that AVPlayer cannot decode directly.
  if ENV['CINEVA_VLC_MIRROR'] == 'github'
    pod 'MobileVLCKit', :podspec => 'Dependencies/MobileVLCKit.podspec.json'
  else
    pod 'MobileVLCKit', '3.7.3'
  end
end
