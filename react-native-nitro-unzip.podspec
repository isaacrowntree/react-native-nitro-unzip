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
  s.platforms    = { ios: '15.5' }
  s.swift_version = '5.9'
  s.module_name  = 'NitroUnzip'

  s.source_files = 'ios/**/*.{h,m,mm,swift,hpp,cpp}'

  # ZIPFoundation — pure-Swift ZIP library with an iterable Archive type.
  # Lets us pre-validate every entry's path BEFORE writing any file and
  # honour Task cancellation between entries — neither possible with
  # SSZipArchive's all-or-nothing unzipFile API.
  s.dependency 'ZIPFoundation', '~> 0.9'

  # Add Nitrogen generated files + NitroModules dependency
  load 'nitrogen/generated/ios/NitroUnzip+autolinking.rb'
  add_nitrogen_files(s)
end
