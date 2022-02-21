#
# To validate podspec run
# pod spec lint bls-signatures-pod.podspec --no-clean --verbose --allow-warnings --skip-import-validation
#
# To submit podspec to the CocoaPods trunk:
# pod trunk push --allow-warnings --skip-import-validation
# 
# Requirements: cmake
#

Pod::Spec.new do |s|
  s.name             = 'bls-signatures-pod'
  s.version          = '0.2.12'
  s.summary          = 'BLS signatures in C++, using the relic toolkit'

  s.description      = <<-DESC
Implements BLS signatures with aggregation as in Boneh, Drijvers, Neven 2018, using relic toolkit for cryptographic primitives (pairings, EC, hashing). The BLS12-381 curve is used.
                       DESC

  s.homepage         = 'https://github.com/Chia-Network/bls-signatures'
  s.license          = { :type => 'Apache License 2.0' }
  s.author           = { 'Chia Network' => 'hello@chia.net' }
  s.social_media_url = 'https://twitter.com/ChiaNetworkInc'

  s.source           = { 
    :git => 'https://github.com/Chia-Network/bls-signatures.git',
    :commit => 'f114ffeff4653e5522d1b3e28687fa9f384a557f',
    :submodules => false
  }

  # Temporary workaround: don't allow CocoaPods to clone and fetch submodules.
  # Fetch submodules _after_ checking out to the needed commit in prepare command.

  s.prepare_command = <<-CMD
  ./bls_build.sh
  CMD

  s.ios.deployment_target = '13.0'
  s.watchos.deployment_target = '5.0'
  s.tvos.deployment_target = '13.0'
  s.osx.deployment_target = '10.15'

  s.library = 'c++'
  s.pod_target_xcconfig = {
    'CLANG_CXX_LANGUAGE_STANDARD' => 'c++14',
    'CLANG_WARN_DOCUMENTATION_COMMENTS' => 'NO',
    'GCC_WARN_64_TO_32_BIT_CONVERSION' => 'NO',
    'GCC_WARN_INHIBIT_ALL_WARNINGS' => 'YES'
  }

  s.osx.source_files = 'artefacts/include/*.hpp'
  s.osx.vendored_libraries = 'artefacts/macosx/libgmp.a', 'artefacts/librelic.a', 'artefacts/libbls.a'

  s.ios.vendored_frameworks = 'DashSharedCore/framework/DashSharedCore.xcframework'
  s.ios.vendored_frameworks = 'artefacts/ios/libbls.xcframework'
  s.watchos.vendored_frameworks = 'artefacts/ios/libbls.xcframework'
  s.tvos.vendored_frameworks = 'artefacts/ios/libbls.xcframework'
  
end
