# Keep the existing application and SPM codec targets; CocoaPods supplies RN only.
require_relative './node_modules/react-native/scripts/react_native_pods'

platform :ios, '18.1'
prepare_react_native_project!

project 'ZipImageViewer.xcodeproj'
target 'ZipImageViewer' do
  config = use_native_modules!
  use_react_native!(
    :path => config[:reactNativePath],
    :app_path => "#{Pod::Config.instance.installation_root}",
    :hermes_enabled => true
  )
  target 'ZipImageViewerTests' do
    inherit! :complete
  end
  post_install do |installer|
    react_native_post_install(installer, config[:reactNativePath], :mac_catalyst_enabled => false)
  end
end
