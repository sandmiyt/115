Pod::Spec.new do |s|
  s.name = 'CinevaFFmpeg'
  s.version = '8.0.2'
  s.summary = 'Cineva private C bridge to a pinned LGPL FFmpeg build'
  s.homepage = 'https://github.com/sandmiyt/115'
  s.author = 'Cineva contributors'
  s.license = { :type => 'LGPL-2.1-or-later', :file => 'LICENSE.txt' }
  s.source = { :http => 'https://ffmpeg.org/releases/ffmpeg-8.0.2.tar.xz',
               :sha256 => '5d16962332603c427b3d0887fc12b9166d6ee2cb1108b1865dd2d5eb06a09505' }
  s.ios.deployment_target = '17.0'
  s.vendored_frameworks = 'Generated/CinevaFFmpeg.xcframework'
  s.preserve_paths = 'Bridge/*', 'build-apple.sh'
end
