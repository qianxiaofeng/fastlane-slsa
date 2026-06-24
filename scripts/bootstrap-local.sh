#!/usr/bin/env bash
# 本地一次性引导脚本：
#   1) 安装工具链（xcodegen、bundler 依赖）
#   2) 生成 Xcode 工程
#   3) 【首次】以可写模式运行 match，登录 Developer Portal 创建并加密证书/profile，
#      推送到你的私有证书仓库。之后 CI 即可 readonly 复用。
#
# 用法：
#   export APP_IDENTIFIER=com.yourorg.app
#   export FASTLANE_USER=you@apple.id
#   export FASTLANE_TEAM_ID=ABCDE12345
#   export MATCH_GIT_URL=https://github.com/you/ios-certificates.git
#   export MATCH_PASSWORD=<解密口令>
#   ./scripts/bootstrap-local.sh
set -euo pipefail

cd "$(dirname "$0")/.."

echo "==> 检查必需环境变量"
: "${APP_IDENTIFIER:?需要设置 APP_IDENTIFIER}"
: "${FASTLANE_USER:?需要设置 FASTLANE_USER (Apple ID)}"
: "${FASTLANE_TEAM_ID:?需要设置 FASTLANE_TEAM_ID}"
: "${MATCH_GIT_URL:?需要设置 MATCH_GIT_URL (私有证书仓库)}"
: "${MATCH_PASSWORD:?需要设置 MATCH_PASSWORD (match 解密口令)}"

echo "==> 安装 xcodegen（如未安装）"
command -v xcodegen >/dev/null 2>&1 || brew install xcodegen

echo "==> 安装 Ruby 依赖（fastlane）"
command -v bundle >/dev/null 2>&1 || gem install bundler
bundle install

echo "==> 生成 Xcode 工程"
( cd ExampleApp && xcodegen generate )

echo "==> 首次 match（可写模式，会登录 Developer Portal 创建/加密证书）"
echo "    若开启了 2FA，请按提示完成验证。"
MATCH_READONLY=false bundle exec fastlane ios setup_signing

echo "==> 完成。证书已加密推送到 ${MATCH_GIT_URL}。"
echo "    接下来在 GitHub 仓库配置 secrets / variables 后即可触发 CI 发布。"
