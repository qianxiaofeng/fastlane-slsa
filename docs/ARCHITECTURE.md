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
> 并用 Workload Identity Federation——见第 7 节。

---

## 5. 上传凭证选型：app-specific password vs App Store Connect API Key

本项目当前用 **Apple ID + app-specific password** 上传 TestFlight（见第 4 节）。这"能用但非最优"，
Apple 与 fastlane 官方都推荐 CI 改用 **App Store Connect API Key（.p8）**。两者的差距不只是"换个凭证"，
而是**权限可收敛性**的根本区别。

### 5.1 app-specific password 的真实风险面

容易误以为它是"上传专用令牌"，其实它是 **Apple ID 的一条旁路认证通道**：任何接受
app-specific password 的 Apple 服务都认它——不止 altool 上传，还包括第三方客户端访问该账号的
**iCloud 邮件 / 通讯录 / 日历**（IMAP/CalDAV/CardDAV）。因此：

- **泄漏后果超出"上传"**：拿到邮箱 + 这个口令，就能以该通道触达账号的 iCloud 数据。
- **账号级、非按 app 隔离**：这个 Apple ID 能上传的所有 app 都在波及范围内，无法收窄。
- **绑定一个真人账号**：该账号在 ASC 里的角色（可能是 Admin/App Manager）、2FA 设备、找回邮箱，
  都成为你必须长期维护的攻击面。

它唯一**做不到**的是网页登录 appleid.apple.com / ASC 后台（需真密码 + 2FA），以及 Spaceship 登录——
后者正是本项目 CI 无法在上传时设置 changelog / 分发测试组的根因。

### 5.2 API Key 能按两个正交维度限制权限

API Key 是**团队级**凭证（Issuer ID + Key ID + `.p8` EC 私钥），客户端本地用 `.p8` 签发 ≤20 分钟的短
JWT，全程不碰 Apple ID、不涉 2FA。它的权限可沿**两个独立维度**收敛：

**维度一 — 角色（role）**：创建 key 时指定，决定"能做哪类操作"。

| 角色 | 能力 | 对本项目 |
|------|------|---------|
| Account Holder | 全部（含法律/银行）；唯一，**不能分配给 key** | — |
| Admin | 几乎全部：管用户、管 app、上传、（可）管证书 | 权限过大，不推荐 |
| **App Manager** | 上传构建、TestFlight、元数据、提审；**勾选后**可管证书 | ✅ 上传 + 写 match 推荐 |
| **Developer** | 上传构建、TestFlight、查看 app 信息；**勾选后**可管证书；不能改元数据/提审 | ✅ 纯上传够用 |
| Marketing / Finance / Sales / Customer Support | 营销 / 财务 / 销售 / 客服，**均不能上传构建** | 不适用 |

**维度二 — key 类型**：决定"能否按 app 收窄"。

| | Team Key | Individual Key |
|---|---|---|
| 作用范围 | **全部 app**，无法限制到单个 app | **继承某用户的 app 访问范围**，可锁到指定 app |
| 权限粒度 | 仅到"角色" | "角色 + 仅这几个 app" |
| 创建者 | Admin / Account Holder | 对应用户自己 |

> **关键坑：证书管理是一个独立勾选项。** "Access to Certificates, Identifiers & Profiles" 现在是
> 单独的权限开关，**不随角色自动开启**——即便是 Admin/Developer/App Manager，也要显式勾上才能经 API 管证书。

### 5.3 对比小结

| 维度 | app-specific password（现状） | App Store Connect API Key |
|------|------|------|
| 本质 | 真人 Apple ID 的旁路口令 | 团队级 API 凭证，本地签发 ≤20 分钟短 token |
| 泄漏爆炸半径 | iCloud + 全部可上传 app，**无法收窄** | 限到**角色**（+ Individual Key 限到 app），不碰 iCloud/真人账号 |
| 需独立真账号 | 需要，且要管 2FA / 找回 | 不需要，无 Apple ID、无 2FA |
| 吊销/轮换 | 在真人账号设置里吊销 | 按 key 独立吊销，可并存多把无缝轮换 |
| CI 能力 | **仅上传** binary | 上传 + changelog + 测试组 + **可写管证书** |
| 对 match | 必须 readonly + 独立 git 证书仓库 | 可让 CI 可写创建证书（git 证书仓库变可选） |

### 5.4 本项目的最小权限建议

1. 用 **Individual Key**（限到目标 app）优于 Team Key；
2. 角色选 **App Manager**；
3. 维持 match 只读 → **不勾**证书权限（纯上传）；若要 CI 可写证书 → 勾上 Certificates/Identifiers/Profiles。

> 两个易混淆的边界：
> 1. **与 SLSA L3 / OIDC 那条线无关**——`.p8` 仍是 GitHub secrets 里的长期密钥，和 `MATCH_PASSWORD` 同级，
>    只是把"人账号旁路口令"换成"可吊销的角色凭证"；要走全短期 OIDC 仍需 WIF（第 7 节）。
> 2. **API Key 解决的是"对 Apple 的认证"**，不消除证书加密文件存哪 / 怎么 clone 的问题——除非改用 API Key
>    在 CI 可写创建证书因而不再预存证书仓库，否则第 4 节的 GitHub App 短期 token clone 逻辑保留。

### 5.5 迁移 delta（仅记录，未在本仓库实施）

- `fastlane/Fastfile`：lane 顶部 `app_store_connect_api_key(key_id:, issuer_id:, key_content:)`，
  `upload_to_testflight` 改传 `api_key:`（即可安全附带 changelog）。
- `fastlane/Appfile`：`apple_id(...)` 一行可删（API Key 不需要 Apple ID）。
- `.github/workflows/build-sign-attest.yml`：env 里 `FASTLANE_USER` +
  `FASTLANE_APPLE_APPLICATION_SPECIFIC_PASSWORD` 两个 secret 换成 `ASC_KEY_ID` / `ASC_ISSUER_ID`
  （可放 variables）+ `ASC_KEY_P8`（secret）。

---

## 6. 验证机制

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

## 7. 后续可演进方向

- 改用 **App Store Connect API Key（.p8）** 替代 Apple ID，让 CI 也能可写管理证书——
  选型、权限模型与迁移 delta 详见第 5 节。
- 把 reusable workflow 抽到**独立的中心仓库**，供组织内多个 app 复用（强化 L3 集中治理）。
- 为 `.dSYM`、SBOM 等附加产物也生成 attestation。
- 在部署/分发环节（如 MDM、企业分发）加入 `gh attestation verify` 作为准入门禁。
