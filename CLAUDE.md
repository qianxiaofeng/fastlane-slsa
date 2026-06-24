# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 这个项目是什么

一个 **PoC**：用 GitHub Actions + fastlane + match + SLSA attestation，把一个最小 iOS app
自动签名、上传 TestFlight，并为 `.ipa` 生成可验证的 **SLSA v1 Build Level 3** provenance。
代码本身是骨架/模板——真正跑通 CI 需要使用者自己的 Apple 账号、证书仓库和 App Store Connect app。

中文是本仓库注释与文档的主语言；新增注释/文档请保持中文。

## 常用命令

本地开发用 `just`（`brew install just`）。**模拟器运行完全不需要 Apple 证书**——签名/上传只发生在 CI。

```bash
just run                 # 生成工程 → 构建 → 装进模拟器 → 启动（一条命令搞定）
just run "iPhone 15"     # 指定模拟器机型（默认 iPhone 17）
just build               # 仅构建（generic 模拟器目标，免签名，不安装）
just generate            # 仅用 XcodeGen 重新生成 .xcodeproj（改了 project.yml 后必跑）
just open                # 用 Xcode 打开工程
just screenshot          # 截当前模拟器到 /tmp/ExampleApp.png
just clean               # 删除 DerivedData 与生成的 .xcodeproj
```

fastlane lanes（需要证书环境，通常在 CI 跑；本地仅 `setup_signing` 首次创建证书时用）：

```bash
bundle exec fastlane ios build           # match(下载证书) → gym 构建签名 .ipa 到 build/ExampleApp.ipa
bundle exec fastlane ios upload          # upload_to_testflight 上传
bundle exec fastlane ios setup_signing   # 仅下载/创建证书与 profile
```

首次本地设置（创建 match 证书，需先 export 一组环境变量，见脚本头部注释）：

```bash
./scripts/bootstrap-local.sh
```

没有测试套件（PoC 无单元测试）。

## 架构：SLSA L3 是怎么达到的

核心不在 fastlane，而在 **GitHub workflow 的分层结构**。理解这点需要同时读 `release.yml`、
`build-sign-attest.yml` 和 `docs/ARCHITECTURE.md`。

```
git tag v1.0.0  ──▶  release.yml (caller，决定"何时发布")
                       │ uses: ./.github/workflows/build-sign-attest.yml
                       │ secrets: inherit
                       ▼
              build-sign-attest.yml (reusable workflow，macOS-26，隔离环境)
               ├─ fastlane match    readonly 从私有证书仓库下载证书（不登录 Developer Portal）
               ├─ fastlane gym      构建签名 build/ExampleApp.ipa
               ├─ attest-build-provenance   ← 生成并 Sigstore 签名 provenance（L3 关键步骤）
               └─ fastlane pilot    上传 TestFlight
```

**L2 与 L3 的分界 = reusable workflow。** 仅仅调用 `attest-build-provenance` 只是 L2；把
*整个构建过程* 封装进 reusable workflow 才是 L3。原因：Sigstore OIDC token 的身份里含
`job_workflow_ref`，于是 provenance 的 `builder.id` 绑定到 reusable workflow 的精确引用，
调用方仓库无法伪造。验证方用 `--signer-workflow` 强制断言签发者身份：

```bash
gh attestation verify ExampleApp.ipa \
  --repo <owner>/<repo> \
  --signer-workflow <owner>/<repo>/.github/workflows/build-sign-attest.yml
```

修改 workflow 时务必保持这个"caller + reusable"分层；把构建步骤搬回 caller 会把等级降到 L2。

## 关键约定与约束

- **bundle id 必须三处一致**：`ExampleApp/project.yml` 的 `PRODUCT_BUNDLE_IDENTIFIER`、
  `fastlane/Appfile`、`fastlane/Matchfile`。默认 `com.example.fastlaneslsa`，也是 `Justfile`
  里 `bundle_id` 的值（改 bundle id 时这四处都要同步）。运行时优先用 `APP_IDENTIFIER` 环境变量覆盖。

- **`.xcodeproj` 不入库**，由 XcodeGen 从 `project.yml` 生成（避免 pbxproj 冲突）。任何 fastlane/CI
  步骤之前都需先 `xcodegen generate`；`just` 命令已自动包含这步。

- **所有账号/凭证信息走环境变量**，不写死进仓库。`Appfile`/`Matchfile` 全部 `ENV[...]` 读取。
  CI 中：非敏感项用 repository **variables**（`APP_IDENTIFIER`、`FASTLANE_TEAM_ID` 等），
  敏感项用 **secrets**（`MATCH_PASSWORD`、`FASTLANE_USER` 等），具体清单见 `README.md`。

- **CI 的 match 永远 readonly**（`MATCH_READONLY=true`）。Fastfile 用 `is_ci` 控制：CI 只下载解密
  证书、不登录 Developer Portal，从而绕过 Apple ID 的 2FA。证书的*创建*只在本地
  `bootstrap-local.sh`（可写 match）发生一次，加密后推到一个**独立的私有 git 仓库**。

- **CI clone 证书仓库用 GitHub App 短期 token,不用长期 PAT**。`build-sign-attest.yml` 里
  `create-github-app-token` 在运行时签发约 1h 失效、仅"只读证书仓库"的 installation token,
  组装成 `MATCH_GIT_BASIC_AUTHORIZATION`(`base64("x-access-token:<token>")`)写入 `$GITHUB_ENV`。
  唯一长期 secret 是 App 私钥（`CERT_REPO_APP_PRIVATE_KEY`）。注意:GitHub Actions OIDC 无法直接
  clone 私有 repo——真·OIDC 只用于 `attest-build-provenance` 的 Sigstore 签名。要让 clone 也走真
  OIDC,需把 match storage 从 git 迁到 GCS/S3 + Workload Identity Federation。

- **上传用 Apple ID + app-specific password**（`FASTLANE_APPLE_APPLICATION_SPECIFIC_PASSWORD`）绕过
  2FA；这个凭证只能用于上传，不能管理证书。若要让 CI 也能可写管理证书，正路是换成
  App Store Connect API Key（.p8）——见 `docs/ARCHITECTURE.md` 的演进方向。

- **构建产物路径是固定契约**：`build/ExampleApp.ipa`。Fastfile 的 `IPA_PATH` 与 workflow 里
  `attest-build-provenance` 的 `subject-path` 必须指向同一文件，否则 attest 的不是真正分发的产物。
