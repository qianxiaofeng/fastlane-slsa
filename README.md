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
                  build-sign-attest.yml  (reusable workflow, macOS-26)
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
| `CERT_REPO_APP_PRIVATE_KEY` | GitHub App 的私钥（.pem 全文），CI 用它签发短期 token 访问证书仓库 |
| `CERT_REPO_APP_CLIENT_ID` | GitHub App 的 **Client ID**（字符串，App 设置页可见）；CI 据此 + 私钥签发短期 token。本身不算敏感，存 secret 只为与私钥统一管理 |
| `FASTLANE_USER` | Apple ID 邮箱 |
| `FASTLANE_APPLE_APPLICATION_SPECIFIC_PASSWORD` | [App-specific password](https://support.apple.com/en-us/102654)，上传时绕过 2FA |

> **不再需要长期 PAT。** 旧版用 `MATCH_GIT_BASIC_AUTHORIZATION`（`base64("用户名:PAT")`）让 CI clone 证书仓库。
> 现在改用一个 **GitHub App** 签发的短期 installation token：CI 运行时才签发、约 1 小时失效、权限锁死到"只读证书仓库"。
> 长期保管的只剩 App 的私钥，作用域远窄于一个能读你账号下所有仓库的 PAT。

设置 GitHub App（一次性）：

1. **Settings → Developer settings → GitHub Apps → New GitHub App**：Repository permissions 只勾 **Contents: Read-only**，其余全部 No access。
2. 安装这个 App 到你的**证书仓库**（仅该仓库，别 All repositories）。
3. 生成一个 **Private key**（.pem），整段内容存为 secret `CERT_REPO_APP_PRIVATE_KEY`。
4. App 设置页的 **Client ID**（字符串，形如 `Iv23li...`，**注意不是数字 App ID**）存为 secret `CERT_REPO_APP_CLIENT_ID`（不算敏感，存 secret 只为统一管理）。

### Repository **variables**（非敏感）

| 名称 | 示例 |
|------|------|
| `APP_IDENTIFIER` | `com.yourorg.app` |
| `FASTLANE_TEAM_ID` | `ABCDE12345` |
| `FASTLANE_ITC_TEAM_ID` | `118xxxxx`（账号属多团队时） |
| `FASTLANE_APP_ID` | App Store Connect 里 app 的数字 ID（可选） |
| `MATCH_GIT_URL` | `https://github.com/you/ios-certificates.git` |
| `CERT_REPO_NAME` | 证书仓库名（不带 owner），如 `ios-certificates`；GitHub App 据此锁定授权范围 |

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

- **上传凭证的最佳实践是 App Store Connect API Key（.p8），而非 Apple ID 账号登录。**
  本项目当前用 **Apple ID + app-specific password** 上传（绕过 2FA），属"能用但非最优"。
  app-specific password 并非"上传专用令牌"，而是 **Apple ID 的旁路认证通道**——同一口令还能经
  IMAP/CalDAV 访问该账号的 iCloud 邮件/通讯录/日历，泄漏波及面**超出"上传"**，且**账号级、无法按 app 收窄**。
  实测它也只够经 altool **上传 binary**；设置 changelog / 分发测试组等 ASC 管理操作会触发 Spaceship 登录、
  在非交互 CI 下失败——故本项目 CI 仅上传 binary、不设 changelog（可事后在 ASC 网页补）。
  **ASC API Key** 则可沿两个维度收敛权限：按**角色**（App Manager / Developer 等最小权限）+ 用
  **Individual Key** 锁到指定 app；不绑个人 Apple ID、不受 2FA 影响、可按 key 独立撤销。
  选型、角色权限矩阵与迁移 delta 详见 [`docs/ARCHITECTURE.md` 第 5 节](docs/ARCHITECTURE.md)。
- **管理证书需要登录 Developer Portal（会触发 2FA）**，因此本项目刻意让 CI 的 `match` 走
  **readonly**，把证书创建留在本地；换用上面的 ASC API Key 后，CI 也能可写管理证书。
- **App 本身需满足 App Store 上传校验**：app 图标（asset catalog + `CFBundleIconName`）、
  屏幕方向声明、以及用 **当年要求的 iOS SDK**（如 iOS 26 SDK / Xcode 26）构建。这些与 SLSA
  provenance 无关，但缺失会让 `upload_to_testflight` 在 altool 阶段报 409 校验失败。
- **所有 GitHub Actions 均已 pin 到 commit SHA**（见 `build-sign-attest.yml` 各 `uses:` 行，`#` 后注明版本号），
  消除可变 tag 被改写带来的供应链风险——这对一个讲供应链安全的项目尤为应当。升级时需同步更新 SHA 与版本注释
  （可借助 Dependabot：它能识别 pinned SHA 并在 PR 里连注释一起 bump）。
- 真正跑通需要你自己的 Apple 账号、证书与 App Store Connect app 记录；本仓库提供的是
  可直接套用的骨架与流程。
