#!/bin/bash
set -euo pipefail

simulator_id="${1:?Usage: bash tools/run_animation_playback_tests.sh SIMULATOR_UDID}"
repository_dir="$(cd "$(dirname "$0")/.." && pwd)"
test_build_dir="$(mktemp -d "${TMPDIR:-/tmp}/animo-animation-playback-tests.XXXXXX")"
trap 'rm -rf "$test_build_dir"' EXIT

ruby - "$repository_dir" "$test_build_dir" <<'RUBY'
require 'xcodeproj'
repository_dir, test_build_dir = ARGV
project = Xcodeproj::Project.new(File.join(test_build_dir, 'AnimationPlaybackTests.xcodeproj'))
host = project.new_target(:application, 'AnimationPlaybackTestHost', :ios, '17.0')
host_source = File.join(test_build_dir, 'AnimationPlaybackTestHost.swift')
File.write(host_source, <<~SWIFT)
  import SwiftUI
  @main struct AnimationPlaybackTestHost: App {
      var body: some Scene { WindowGroup { Text("Animation pause and resume tests") } }
  }
SWIFT
host.source_build_phase.add_file_reference(project.main_group.new_file(host_source))
target = project.new_target(:unit_test_bundle, 'AnimationPlaybackTests', :ios, '17.0')
target.add_dependency(host)
%w[
  Animo3D/Rendering/Animation/AnimationPlaybackClock.swift
  Animo3D/Rendering/Animation/VRMAnimationPlayer.swift
  Animo3D/Rendering/Animation/VRMAnimationClip.swift
  Animo3D/Shared/Utilities/Extensions.swift
  tools/tests/AnimationPlaybackTests.swift
].each do |path|
  target.source_build_phase.add_file_reference(project.main_group.new_file(File.join(repository_dir, path)))
end
localizations = project.main_group.new_variant_group('Localizable.strings')
Dir.glob(File.join(repository_dir, 'Animo3D/Resources/*.lproj/Localizable.strings')).sort.each do |path|
  reference = localizations.new_file(path)
  reference.name = File.basename(File.dirname(path), '.lproj')
end
host.resources_build_phase.add_file_reference(localizations)
project.root_object.known_regions = %w[en de es fr ja ko pt]
[host, target].each do |build_target|
  build_target.build_configurations.each do |configuration|
    configuration.build_settings['GENERATE_INFOPLIST_FILE'] = 'YES'
    configuration.build_settings['PRODUCT_BUNDLE_IDENTIFIER'] = "com.animar.animo.#{build_target.name}"
    configuration.build_settings['SWIFT_VERSION'] = '5.0'
    configuration.build_settings['ENABLE_TESTING_SEARCH_PATHS'] = 'YES'
    configuration.build_settings['CODE_SIGNING_ALLOWED'] = 'NO'
    configuration.build_settings['TARGETED_DEVICE_FAMILY'] = '1,2'
  end
end
target.build_configurations.each do |configuration|
  configuration.build_settings['TEST_HOST'] = '$(BUILT_PRODUCTS_DIR)/AnimationPlaybackTestHost.app/AnimationPlaybackTestHost'
  configuration.build_settings['BUNDLE_LOADER'] = '$(TEST_HOST)'
end
scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(host)
scheme.add_build_target(target)
scheme.set_launch_target(host)
scheme.add_test_target(target)
if ENV['ANIMO_TEST_LANGUAGE']
  scheme.test_action.xml_element.add_attribute('language', ENV['ANIMO_TEST_LANGUAGE'])
end
scheme.save_as(project.path, 'AnimationPlaybackTests')
project.save
RUBY

xcodebuild \
    -project "$test_build_dir/AnimationPlaybackTests.xcodeproj" \
    -scheme AnimationPlaybackTests \
    -destination "platform=iOS Simulator,id=$simulator_id" \
    -derivedDataPath "$test_build_dir/build" \
    -resultBundlePath "$test_build_dir/AnimationPlaybackTests.xcresult" \
    -parallel-testing-enabled NO \
    test

if [[ -n "${ANIMO_TEST_ARTIFACTS:-}" ]]; then
    xcrun xcresulttool export attachments \
        --path "$test_build_dir/AnimationPlaybackTests.xcresult" \
        --output-path "$ANIMO_TEST_ARTIFACTS"
fi
