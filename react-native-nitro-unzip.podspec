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
  # Swift 6 language mode with complete concurrency checking. Migrating to it
  # surfaced (and fixed) two real defects: NSLock held across `await` in the
  # async extract/compress paths, and unsynchronised progress-throttle state
  # mutated from SSZipArchive's worker threads. Both Hybrid task classes are
  # `@unchecked Sendable` with every mutable field guarded by their `lock`.
  s.swift_version = '6.0'
  s.module_name  = 'NitroUnzip'

  s.pod_target_xcconfig = {
    'SWIFT_STRICT_CONCURRENCY' => 'complete',
  }

  s.source_files = 'ios/**/*.{h,m,mm,swift,hpp,cpp}'
  s.exclude_files = 'ios/Tests/**/*'

  # ZIPFoundation — pure-Swift ZIP library with an iterable Archive type.
  # Used for everything EXCEPT password-protected ZIP CREATION (write).
  # Lets us pre-validate every entry's path BEFORE writing any file and
  # honour Task cancellation between entries — neither possible with
  # SSZipArchive's all-or-nothing unzipFile API.
  s.dependency 'ZIPFoundation', '~> 0.9'

  # SSZipArchive — retained ONLY as a fallback for password-protected
  # ZIP CREATION. ZIPFoundation's password support is read-only (AES
  # decrypt) and would otherwise force a regression on the public
  # `zipWithPassword` API. Read paths and unencrypted-write paths all
  # use ZIPFoundation; only `ZipEngine.compressWithPassword` reaches
  # for SSZipArchive.
  s.dependency 'SSZipArchive', '~> 2.6'

  # Add Nitrogen generated files + NitroModules dependency
  load 'nitrogen/generated/ios/NitroUnzip+autolinking.rb'
  add_nitrogen_files(s)
end
