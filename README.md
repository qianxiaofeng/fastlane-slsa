# fastlane-slsa

用 **GitHub Actions + fastlane + match + SLSA attestation**，把一个 iOS app 自动
签名、上传到 **App Store Connect / TestFlight**，并为产物（`.ipa`）生成可验证的
**SLSA v1 Build Level 3** provenance（供应链来源证明）。

这是一个**从零搭建的完整 PoC**：包含一个最小 SwiftUI 示例 app、fastlane 配置、
以及达到 SLSA L3 的 GitHub Actions 工作流。

---

## 它做到了什么

```
git tag v1.0.0  ──push──▶  release.yml (caller)
                              │ 调用（secrets: inherit）
                              ▼
                  build-sign-attest.yml  (reusable workflow, macOS-14)
                   ├─ fastlane match   下载证书/profile（readonly，不碰 Developer Portal）
                   ├─ fastlane gym     构建签名 .ipa
                   ├─ attest-build-provenance   ← 生成并签名 SLSA provenance（L3 关键）
                   └─ fastlane pilot   上传 TestFlight（Apple ID + app-specific password）
```

任何人事后都能验证这个 `.ipa` 确实由本仓库的这条工作流构建：

```bash
gh attestation verify ExampleApp.ipa \
  --repo <owner>/<repo> \
  --signer-workflow <owner>/<repo>/.github/workflows/build-sign-attest.yml
```

---

## 为什么是 SLSA Level 3（而不是 L2）

| 用法 | 等级 |
|------|------|
| 普通 job 里直接调 `attest-build-provenance` | L2 |
| **整个构建过程封装进 reusable workflow** 再生成 provenance（本项目） | **L3** |

L3 的关键：provenance 的 `builder.id` 绑定到 reusable workflow 的引用，由 Sigstore + OIDC
签名，调用方仓库无法伪造。详见 [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)。

---

## 目录结构

```
.
├── ExampleApp/                  # 最小 SwiftUI app（用 XcodeGen 生成工程）
│   ├── project.yml              #   XcodeGen 配置（.xcodeproj 不入库）
│   └── Sources/*.swift
├── fastlane/
│   ├── Appfile                  # 账号/app 信息（全部读环境变量）
│   ├── Matchfile                # match：私有 git 仓库存证书
│   └── Fastfile                 # build / upload lanes
├── .github/workflows/
│   ├── release.yml              # caller：何时发布
│   └── build-sign-attest.yml    # reusable：构建+attest+上传（L3 核心）
├── scripts/bootstrap-local.sh   # 本地一次性：装工具、生成工程、首次 match
├── Gemfile
└── docs/ARCHITECTURE.md
```

---

## 前置条件

- 一个 Apple Developer Program 账号、一个 bundle identifier、以及该 app 在 App Store Connect 已创建。
- 一个**独立的私有 git 仓库**用于 match 存放加密证书（例：`github.com/you/ios-certificates`）。
- 本机：Xcode 16+、Ruby、Homebrew。

---

## 一、本地首次设置（创建证书）

`match` 的证书需要在本地以可写模式创建一次，之后 CI 只读复用。

```bash
export APP_IDENTIFIER=com.yourorg.app
export FASTLANE_USER=you@apple.id
export FASTLANE_TEAM_ID=ABCDE12345          # Developer Portal Team ID
export MATCH_GIT_URL=https://github.com/you/ios-certificates.git
export MATCH_PASSWORD='一个强口令'           # 用于加解密证书

./scripts/bootstrap-local.sh
```

脚本会：安装 `xcodegen` → `bundle install` → 生成工程 → 运行可写 `match`
（按提示完成 Apple ID 2FA），把加密证书推送到你的私有证书仓库。

> 同时把 `ExampleApp/project.yml` 和 `fastlane/*` 里的 `com.example.fastlaneslsa`
> 改成你自己的 bundle id（或始终用 `APP_IDENTIFIER` 环境变量覆盖）。

---

## 二、在 GitHub 仓库配置 Secrets 与 Variables

**Settings → Secrets and variables → Actions**

### Repository **secrets**（敏感）

| 名称 | 说明 |
|------|------|
| `MATCH_PASSWORD` | match 解密口令（与本地一致） |
| `MATCH_GIT_BASIC_AUTHORIZATION` | `base64("用户名:个人访问令牌")`，让 CI 能 clone 私有证书仓库 |
| `FASTLANE_USER` | Apple ID 邮箱 |
| `FASTLANE_APPLE_APPLICATION_SPECIFIC_PASSWORD` | [App-specific password](https://support.apple.com/en-us/102654)，上传时绕过 2FA |

生成 `MATCH_GIT_BASIC_AUTHORIZATION`：

```bash
echo -n "your-gh-username:ghp_xxxxToken" | base64
```

### Repository **variables**（非敏感）

| 名称 | 示例 |
|------|------|
| `APP_IDENTIFIER` | `com.yourorg.app` |
| `FASTLANE_TEAM_ID` | `ABCDE12345` |
| `FASTLANE_ITC_TEAM_ID` | `118xxxxx`（账号属多团队时） |
| `FASTLANE_APP_ID` | App Store Connect 里 app 的数字 ID（可选） |
| `MATCH_GIT_URL` | `https://github.com/you/ios-certificates.git` |

---

## 三、触发发布

```bash
git tag v1.0.0
git push origin v1.0.0          # 自动构建 + attest + 上传 TestFlight
```

或在 **Actions → Release → Run workflow** 手动触发（可勾选是否上传 TestFlight）。

---

## 四、验证 SLSA Provenance

构建产物的 attestation 自动存到 GitHub（Sigstore 公共透明日志）。下载 `.ipa` 后：

```bash
gh attestation verify ExampleApp.ipa \
  --repo <owner>/<repo> \
  --signer-workflow <owner>/<repo>/.github/workflows/build-sign-attest.yml
```

`--signer-workflow` 强制要求该 attestation 必须由我们的 reusable workflow 签发——
这正是 L3 "不可伪造" 的落地校验。

---

## 已知限制 / 设计取舍

- **Apple ID + app-specific password**：在 CI 里只能用于**上传**；管理证书需要登录
  Developer Portal（会触发 2FA），因此本项目刻意让 CI 的 `match` 走 **readonly**，
  把证书创建留在本地。若想让 CI 也能管理证书，更顺的方式是改用
  **App Store Connect API Key（.p8）**。
- `actions/attest-build-provenance@v1` 建议在生产中固定到 commit SHA。
- 真正跑通需要你自己的 Apple 账号、证书与 App Store Connect app 记录；本仓库提供的是
  可直接套用的骨架与流程。
