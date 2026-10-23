Pod::Spec.new do |s|
  s.name             = 'sound_link'
  s.version          = '0.0.1'
  s.summary          = 'Send and receive small data payloads over near-ultrasonic sound.'
  s.description      = <<-DESC
Send and receive small data payloads over near-ultrasonic sound on Android and iOS, with signal-strength metrics.
                       DESC
  s.homepage         = 'https://github.com/Vjex/sound_link'
  s.license          = { :file => '../LICENSE' }
  s.author           = 'Vishal Verma'
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.public_header_files = 'Classes/SLCoreBridge.h'
  s.dependency 'Flutter'
  s.platform = :ios, '13.0'
  s.frameworks = 'AVFoundation', 'CallKit'
  s.library = 'c++'

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386',
    'CLANG_CXX_LANGUAGE_STANDARD' => 'c++17',
    'CLANG_CXX_LIBRARY' => 'libc++',
    'GCC_PREPROCESSOR_DEFINITIONS' => '$(inherited) GGWAVE_DISABLE_LOG=1',
    'HEADER_SEARCH_PATHS' => '$(inherited) "${PODS_TARGET_SRCROOT}/../src" "${PODS_TARGET_SRCROOT}/../src/ggwave/include"',
    'GCC_OPTIMIZATION_LEVEL' => 's',
  }
  s.swift_version = '5.0'
  s.resource_bundles = {'sound_link_privacy' => ['Resources/PrivacyInfo.xcprivacy']}
end
