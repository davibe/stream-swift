Pod::Spec.new do |spec|
    spec.name         = 'StreamSwift'
    spec.version      = '0.0.1'
    spec.license      = { :type => 'MIT' }
    spec.homepage     = 'https://github.com/davibe/stream-swift'
    spec.authors      = { 'Davide Bertola' => 'dade@dadeb.it' }
    spec.summary      = 'asd'
    spec.platform     = :osx, "10.12"
    spec.source       = { :git => 'https://github.com/davibe/stream-swift.git' }
    spec.source_files = 'stream-swift/Stream.swift'
  end