Pod::Spec.new do |s|
  s.name = 'podoco_flutter'
  s.version = '0.1.0'
  s.summary = 'Offline app-bundled model resources for Podoco.'
  s.description = 'Locates immutable Flutter assets without copying or downloading models.'
  s.homepage = 'https://github.com/yunho-c/podofo'
  s.license = { :file => '../LICENSE' }
  s.author = { 'Podoco contributors' => 'https://github.com/yunho-c/podofo' }
  s.source = { :path => '.' }
  s.source_files = 'Classes/**/*'
  s.dependency 'FlutterMacOS'
  s.platform = :osx, '15.0'
  s.swift_version = '5.0'
end
