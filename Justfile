# Justfile —— 本地开发常用命令。安装 just：brew install just
#
# 最常用：
#   just run            生成工程 → 构建 → 装进模拟器 → 启动（一条命令）
#   just run "iPhone 15"  指定模拟器机型
#
# 模拟器运行【不需要任何 Apple 证书】（签名/上传只在 CI 里发生）。

# —— 可配置项 ——
project_dir := "ExampleApp"
xcodeproj   := "ExampleApp/ExampleApp.xcodeproj"
scheme      := "ExampleApp"
# bundle id 走 APP_IDENTIFIER 环境变量（真实值不入库）；未设时回退到占位符。
# generate 时把它 export 给 xcodegen 供 ${APP_IDENTIFIER} 替换，launch 时也用它——两边同源，保证一致。
bundle_id   := env_var_or_default("APP_IDENTIFIER", "com.example.fastlaneslsa")
derived     := "ExampleApp/DerivedData"
app_path    := derived / "Build/Products/Debug-iphonesimulator" / scheme + ".app"

# 默认：列出所有命令
default:
    @just --list

# 用 XcodeGen 生成 .xcodeproj（project.yml 改动后需重跑）
# 把 bundle_id 注入环境，供 project.yml 的 ${APP_IDENTIFIER} 替换。
generate:
    cd {{project_dir}} && APP_IDENTIFIER={{bundle_id}} xcodegen generate

# 一条命令：生成 → 构建 → 装进模拟器 → 启动。可传机型，如 `just run "iPhone 15"`
run simulator="iPhone 17": generate
    #!/usr/bin/env bash
    set -euo pipefail
    # 取第一个匹配机型的可用模拟器 UDID（build 与 install 用同一台，保持一致）
    udid=$(xcrun simctl list devices available \
        | grep -E "^[[:space:]]*{{simulator}} \(" \
        | head -1 | grep -oiE '[0-9a-f]{8}-([0-9a-f]{4}-){3}[0-9a-f]{12}' || true)
    if [ -z "$udid" ]; then
        echo "找不到可用模拟器：{{simulator}}。可用机型："
        xcrun simctl list devices available | grep -iE 'iphone|ipad'
        exit 1
    fi
    echo "==> 使用模拟器 {{simulator}} ($udid)"

    echo "==> 构建（模拟器，免签名）"
    xcodebuild -project {{xcodeproj}} -scheme {{scheme}} -configuration Debug \
        -destination "platform=iOS Simulator,id=$udid" \
        -derivedDataPath {{derived}} \
        CODE_SIGNING_ALLOWED=NO build | tail -1

    echo "==> 启动模拟器并安装运行"
    xcrun simctl boot "$udid" 2>/dev/null || true
    open -a Simulator
    xcrun simctl bootstatus "$udid" -b
    xcrun simctl install "$udid" "{{app_path}}"
    xcrun simctl launch "$udid" {{bundle_id}}
    echo "==> 已在模拟器中启动 {{scheme}}"

# 仅构建（generic 模拟器目标，不安装）
build: generate
    xcodebuild -project {{xcodeproj}} -scheme {{scheme}} -configuration Debug \
        -sdk iphonesimulator -derivedDataPath {{derived}} \
        CODE_SIGNING_ALLOWED=NO build

# 截当前模拟器屏幕到 /tmp/{{scheme}}.png
screenshot:
    xcrun simctl io booted screenshot /tmp/{{scheme}}.png
    @echo "已保存 /tmp/{{scheme}}.png"

# 用 Xcode 打开工程
open: generate
    open {{xcodeproj}}

# 清理生成的工程与构建产物
clean:
    rm -rf {{derived}} {{xcodeproj}}
    @echo "已清理 DerivedData 与生成的 .xcodeproj"
