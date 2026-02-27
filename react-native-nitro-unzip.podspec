require 'json'

package = JSON.parse(File.read(File.join(__dir__, 'package.json')))

Pod::Spec.new do |s|
  s.name         = 'react-native-nitro-unzip'
  s.version      = package['version']
  s.summary      = package['description']
  s.homepage     = package['homepage']
  s.license      = package['license']
  s.authors      = package['author']
  s.source       = { git: package['repository']['url'], tag: s.version.to_s }
  s.platforms    = { ios: '13.0' }
  s.swift_version = '5.9'

  s.source_files = 'ios/**/*.{h,m,mm,swift,hpp,cpp}'

  # SSZipArchive — C-based libz decompression for maximum performance
  s.dependency 'SSZipArchive', '~> 2.5'

  # Add Nitrogen generated files + NitroModules dependency
  load 'nitrogen/generated/ios/NitroUnzip+autolinking.rb'
  add_nitrogen_files(s)
end
