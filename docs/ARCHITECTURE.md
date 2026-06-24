# 架构与 SLSA 等级说明

本文解释本项目如何用 GitHub 原生 attestation 达到 **SLSA v1 Build Level 3**，
以及各组件之间的信任边界。

---

## 1. SLSA Build Level 速览

SLSA（Supply-chain Levels for Software Artifacts）的 **Build track** 关注"产物是否
由可信、可追溯、不可被篡改的流程构建"。

| 等级 | 核心要求 | 本项目如何满足 |
|------|----------|----------------|
| **L1** | 有 provenance（记录怎么构建的） | attest-build-provenance 生成 in-toto provenance |
| **L2** | provenance 由托管构建平台签名、可验证 | GitHub 托管 runner + Sigstore 签名 |
| **L3** | provenance **不可伪造**，构建在隔离环境、签名材料构建任务不可触及 | **把整个构建放进 reusable workflow** |

---

## 2. L2 与 L3 的真正分界：reusable workflow

很多人以为"只要加了 `attest-build-provenance` 就是 L3"，**这是错的**：

- 在**普通 job** 里直接调用 attest → 只有 **L2**。因为构建步骤和签名步骤在同一个
  由调用方仓库完全控制的 job 里，理论上构建脚本能影响 provenance 内容。
- 把**整个构建过程**移进一个 **reusable workflow**，由它来生成 provenance → **L3**。

### 为什么 reusable workflow 能达到 L3？

GitHub 在签发 Sigstore OIDC token 时，token 的身份里包含 `job_workflow_ref`——
即**实际执行构建的 reusable workflow 的精确引用**
（`owner/repo/.github/workflows/build-sign-attest.yml@<sha>`）。

于是签名证书绑定的是 **reusable workflow 的身份**，而不是调用方 job。这带来两点：

1. **集中可控**：构建定义在 repo 之外、可被组织统一审计与锁定，调用方仓库改不了它。
2. **不可伪造**：验证方可以用 `--signer-workflow` 要求 "必须由这个 workflow 签发"，
   任何绕过该 workflow 的构建都无法产生通过验证的 attestation。

这正是 SLSA L3 要求的 "non-falsifiable provenance + isolated build"。

> 注意：iOS 必须在 **macOS runner** 上构建。macOS 托管 runner 同样是 GitHub 提供的
> 一次性（ephemeral）隔离环境，attest-build-provenance 基于 Sigstore 跨平台可用，
> 因此在 macOS 上同样成立 L3。

---

## 3. 端到端时序

```
开发者                  caller workflow            reusable workflow (macOS, 隔离)         外部服务
  │  git push v1.0.0          │                              │
  │ ─────────────────────────▶│                              │
  │                           │  uses: build-sign-attest.yml │
  │                           │ ─────────────────────────────▶│
  │                           │                              │  match (readonly)
  │                           │                              │ ─────────────▶ 私有证书 git 仓库
  │                           │                              │ ◀───────────── 加密证书/profile
  │                           │                              │  (用 MATCH_PASSWORD 解密)
  │                           │                              │
  │                           │                              │  gym → 构建 ExampleApp.ipa
  │                           │                              │
  │                           │                              │  attest-build-provenance
  │                           │                              │ ─────────────▶ Sigstore (OIDC 签名)
  │                           │                              │ ◀───────────── 短期证书 + 透明日志
  │                           │                              │  provenance 存入 GitHub attestations
  │                           │                              │
  │                           │                              │  pilot 上传（app-specific pwd）
  │                           │                              │ ─────────────▶ App Store Connect / TestFlight
```

---

## 4. 凭证与信任边界

| 凭证 | 用途 | 为什么这样放 |
|------|------|--------------|
| `MATCH_PASSWORD` | 解密证书 | CI 只读解密，不需要 Apple 登录；对称口令无法联邦化，只能当 secret |
| GitHub App **短期 token** | clone 私有证书仓库 | 取代长期 PAT：运行时签发、约 1h 失效、权限锁死"只读证书仓库"。长期保管的只剩 App 私钥 |
| `FASTLANE_USER` + app-specific password | 上传 TestFlight | app-specific password 绕过 2FA，仅上传可用 |
| Sigstore OIDC token | 签名 provenance | 由 GitHub 在 runner 内短期签发，**不是仓库 secret**，构建脚本无法导出 |

关键设计：**签名 provenance 用的不是任何长期密钥**，而是 GitHub 运行时签发、绑定
workflow 身份的短期 OIDC token + Sigstore 短期证书。这就是 L3 "签名材料构建任务不可
窃取" 的体现。

> **凭证短期化的边界**：GitHub Actions OIDC（`id-token`）只能给 Sigstore/外部云做身份联邦，
> **不能直接 clone 私有 GitHub 仓库**。因此证书存储维持 git 模式时，clone 凭证用 **GitHub App
> 短期 installation token**（最接近 OIDC 的等价物），把唯一长期密钥从"能读账号下所有仓库的 PAT"
> 收敛成"只读单个证书仓库的 App 私钥"。若想把这一步也换成真·OIDC，需把证书存储迁到 GCS/S3
> 并用 Workload Identity Federation——见第 6 节。

---

## 5. 验证机制

```bash
gh attestation verify ExampleApp.ipa \
  --repo <owner>/<repo> \
  --signer-workflow <owner>/<repo>/.github/workflows/build-sign-attest.yml
```

`gh attestation verify` 会：
1. 按 `.ipa` 的 sha256 摘要，从 GitHub/Sigstore 拉取对应 attestation；
2. 校验 Sigstore 签名链与透明日志条目；
3. 用 `--signer-workflow` 断言签发者必须是我们的 reusable workflow。

三者全过才算可信——这把 "产物 → 构建流程 → 签名身份" 串成一条可验证的链。

---

## 6. 后续可演进方向

- 改用 **App Store Connect API Key（.p8）** 替代 Apple ID，让 CI 也能可写管理证书。
- 把 reusable workflow 抽到**独立的中心仓库**，供组织内多个 app 复用（强化 L3 集中治理）。
- 为 `.dSYM`、SBOM 等附加产物也生成 attestation。
- 在部署/分发环节（如 MDM、企业分发）加入 `gh attestation verify` 作为准入门禁。
