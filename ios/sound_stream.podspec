#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint sound_stream.podspec' to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'sound_stream'
  s.version          = '0.0.1'
  s.summary          = 'A flutter plugin for streaming speech data segments from mic'
  s.description      = <<-DESC
  A flutter plugin for streaming only speech audio data in segments from mic
                       DESC
  s.homepage         = 'https://github.com/hn12404988/flutter-speech-stream'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Willy Forsure' => 'forsure.willy@gmail.com' }
  s.source           = { :path => '.' }
  s.source_files = 'Classes/**/*'
  s.dependency 'Flutter'
  s.frameworks = 'SoundAnalysis', 'Accelerate', 'Foundation', 'CoreML'
  s.platform = :ios, '13.0'

  # Flutter.framework does not contain a i386 slice. Only x86_64 simulators are supported.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'VALID_ARCHS[sdk=iphonesimulator*]' => 'x86_64' }
  s.swift_version = '5.0'
end
