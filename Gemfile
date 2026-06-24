source "https://rubygems.org"

# fastlane：iOS 构建、签名(match)、上传(pilot/deliver) 的核心工具链
gem "fastlane"

# CocoaPods 暂未使用；如果示例 app 引入第三方依赖再放开
# gem "cocoapods"

plugins_path = File.join(File.dirname(__FILE__), "fastlane", "Pluginfile")
eval_gemfile(plugins_path) if File.exist?(plugins_path)
