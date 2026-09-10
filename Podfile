platform :ios, '15.0'

target 'Animo3D' do
  use_frameworks!
  pod 'MediaPipeTasksVision'
  # Analytics only. The rest of Firebase is not wired up, and each extra subspec is another
  # framework to load at launch on the low-end devices this app still supports.
  pod 'FirebaseAnalytics'
end

post_install do |installer|
  installer.pods_project.targets.each do |t|
    t.build_configurations.each do |config|
      config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '15.0'
    end
  end
end
