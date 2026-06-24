# SLSA Provenance 内容与证据链分析

本文拆解本项目产出的 SLSA Provenance **具体是什么、每一步往里写了什么、以及它如何
串成一条可被任何人独立验证的证据链**。这里**不纠缠 SLSA 等级之争**（等级与 reusable
workflow 的关系见 [`ARCHITECTURE.md`](ARCHITECTURE.md)），只回答一个问题：

> 别人拿到一个 `ExampleApp.ipa`，凭什么能**密码学地确信**它确实由本仓库的这条公开
> 工作流构建，而不是某人在自己机器上打包、冒名顶替的？

> 关于"这条链最终把信任落在谁身上"（GitHub / Sigstore / Rekor 可信的前提），
> 见 [`TRUST-MODEL.md`](TRUST-MODEL.md)。

---

## 1. 整条逻辑在做什么（不分等级）

本质是一条 **"自动签名 + 可溯源分发"流水线**，做五件事，前后有强依赖：

1. **触发与隔离**：推 `v*` tag → caller 把构建整个委托给 reusable workflow，跑在
   GitHub 托管的一次性 macOS runner 上（用完即弃、无残留状态）。
2. **签出能装机的 .ipa**：`match` 只读下载加密证书 → `MATCH_PASSWORD` 解密 → `gym`
   用 **Apple 代码签名** 产出 `build/ExampleApp.ipa`。这套签名回答的是"**这 app 能不能跑**"，
   **不回答"它从哪来"**。
3. **给这个 .ipa 生成"出生证明"并签名**：`attest-build-provenance` 对 `.ipa` 算 sha256，
   组装一份 in-toto 声明（谁、何时、用哪个 commit 的源码、在哪一次 run 构建），用
   **Sigstore 签名**、写入 **Rekor 公开透明日志**。这套签名回答的恰恰是"**它从哪来**"。
4. **分发**：出生证明签完、存档之后，才用 app-specific password 上传 TestFlight。
   顺序是刻意的——**先有可验证来源，再分发**。
5. **事后验证**：任何人用 `gh attestation verify` 重走整条链（见第 5 节）。

> **两套签名别混**：第 2 步的 **Apple 代码签名**（让设备愿意运行）与第 3 步的
> **Sigstore 溯源签名**（证明来源）彼此独立、互不替代。

---

## 2. Provenance 到底是"一份什么东西"

`attest-build-provenance`（`build-sign-attest.yml` 的"生成 SLSA Build Provenance"步骤）
产出的不是日志，而是一份**经 Sigstore 签名的 in-toto 声明**（SLSA Provenance v1 predicate），
结构大致如下：

```jsonc
{
  "_type": "https://in-toto.io/Statement/v1",
  // ① 被证明的产物 —— 用摘要而非文件名锁定身份
  "subject": [{ "name": "ExampleApp.ipa", "digest": { "sha256": "<ipa 的 sha256>" } }],

  "predicateType": "https://slsa.dev/provenance/v1",
  "predicate": {
    "buildDefinition": {
      "buildType": "https://actions.github.io/buildtypes/workflow/v1",
      // ② 构建是"由什么 workflow、在什么 ref、被什么事件"触发的
      "externalParameters": {
        "workflow": {
          "repository": "https://github.com/<owner>/<repo>",
          "ref": "refs/tags/v1.0.0",
          "path": ".github/workflows/build-sign-attest.yml"   // ← reusable workflow，不是 caller
        }
      },
      "internalParameters": { "github": { "event_name": "push", "repository_id": "…", … } },
      // ③ 构建消费的源码，绑定到具体 git commit
      "resolvedDependencies": [
        { "uri": "git+https://github.com/<owner>/<repo>@refs/tags/v1.0.0",
          "digest": { "gitCommit": "<sha>" } }
      ]
    },
    "runDetails": {
      // ④ 最关键：签发者身份 = reusable workflow 的精确引用
      "builder": { "id": "https://github.com/<owner>/<repo>/.github/workflows/build-sign-attest.yml@refs/tags/v1.0.0" },
      "metadata": { "invocationId": "https://github.com/…/actions/runs/<run-id>/attempts/1" }
    }
  }
}
```

这份声明被装进 **DSSE 信封**，用 **Sigstore** 签名（从 OIDC token 换来的 Fulcio 短期证书），
并把签名条目写进 **Rekor 透明日志**。其中四个字段是证据链的四个着力点：
`subject.digest.sha256`、`builder.id`、Sigstore 签名链、Rekor 条目。

---

## 3. 逐步：每一步对证据链贡献了什么

按 `build-sign-attest.yml` 的执行顺序，只标注**它在证据链里扮演什么角色**（纯依赖安装步骤略过）：

| 步骤 | 做了什么 | 对证据链的贡献 |
|------|----------|----------------|
| `release.yml` `uses: ./…/build-sign-attest.yml` | caller 把整个构建委托给 reusable workflow | GitHub 签发 OIDC token 时，`job_workflow_ref` 指向**实际在跑的 reusable workflow**，后面 `builder.id` 的身份来源于此 |
| `release.yml` `permissions: id-token / attestations: write` | caller 把 OIDC 与 attestation 写权限**下放**给 reusable | reusable 拿不到超过 caller 授予的权限；没有 `id-token: write` 就拿不到 OIDC token，签名环直接断裂 |
| Checkout | 拉源码到隔离的 macOS runner | 确立"构建发生在 GitHub 托管的一次性环境"；此处 commit 后来体现在 `resolvedDependencies` |
| `match`（Fastfile `build` lane） | **只读**下载 Apple 证书 | ⚠️ 这是 **Apple 代码签名** 用的，与 SLSA 无关。两套签名别混（见第 1 节） |
| **构建签名 .ipa → gym** | 产出 `build/ExampleApp.ipa`（固定契约路径） | 生成**被证明的产物本体**。`IPA_PATH` 必须 = attest 的 `subject-path`，否则证明的不是分发的那个文件 |
| 打印产物 SHA-256 | 算 `.ipa` 的 sha256 写进日志 | **人类可核对的旁证**（非必需环）；真正进 provenance 的摘要由下一步 action 自己重算 |
| **生成 SLSA Build Provenance** | 算摘要 → 组装 in-toto 声明 → 取 OIDC token → 找 Fulcio 换短期证书 → 签 DSSE → 写 Rekor → 存进 GitHub attestations | **证据链在这里被锻造并签名**。紧跟 build 之后、upload 之前，保证签的就是真正分发的那个 `.ipa` |
| 生成 SBOM（Syft） | 扫仓库依赖来源 → `build/ExampleApp.sbom.spdx.json` | 产出依赖清单，回答"**用了什么**"（本项目以构建工具链为主，见第 7 节） |
| 生成 SBOM attestation | 把 SBOM 绑定到与 provenance 相同的 `.ipa` digest，走同一套 Sigstore 签名 | **第二份 attestation**，与 provenance 平行、互补（见第 7 节） |
| 上传 TestFlight | `pilot` 用 app-specific password 上传 binary | 分发动作，**在 attest 之后**。先有 provenance/SBOM 再分发，顺序不能颠倒 |
| 归档 .ipa | upload-artifact 存档 | 留存可供事后 `gh attestation verify` 的产物副本 |

> 那个"签发证书仓库短期访问 token / 组装 match git 凭证"的步骤**不在 SLSA 证据链上**——
> 它只为 `match` clone 私有证书仓库服务（Apple 侧）。SLSA 这条线用的是另一套：
> `id-token: write` 换来的真·OIDC token，只喂给 Sigstore。两条凭证线刻意分开（见第 6 节）。

---

## 4. 证据链：四个环如何环环相扣

SLSA 的"可验证"本质，是把 **产物 → 构建过程 → 签发身份 → 不可抵赖** 串成一条没有断点的链。
每一环都用密码学摘要 / 签名绑死上一环：

```
  ┌─ 环1 ─┐        ┌─ 环2 ─┐         ┌──────── 环3 ────────┐      ┌─ 环4 ─┐
 .ipa 文件 ──sha256──▶ subject ──写入──▶ provenance 声明 ──签名──▶ Fulcio 短期证书 ──记录──▶ Rekor
                                            │                        ▲  SAN 来自
                                       builder.id ◀────必须一致──── OIDC.job_workflow_ref
                                  (reusable workflow ref)        (GitHub 签发，构建脚本碰不到)
```

**环 1 — 产物 ↔ 摘要**：provenance 不记文件名，记 `subject.digest.sha256`。换一个字节，
摘要变，验证立刻失败。文件名 `ExampleApp.ipa` 只是标签。

**环 2 — 摘要 ↔ 构建过程**：这份带摘要的声明里同时写了 `externalParameters.workflow`
（谁触发、哪个 ref）、`resolvedDependencies`（哪个 git commit 的源码）、`invocationId`
（哪一次 run）。于是"这个摘要的产物"被钉死到"这一次具体构建"。

**环 3 — 构建过程 ↔ 签发身份（命门）**：
- GitHub 在 runner 内签发 OIDC token，claim 里含 `job_workflow_ref` = **实际执行构建的
  reusable workflow 的精确引用**。
- Sigstore 拿这个 token 去 Fulcio 换证书，把 `job_workflow_ref` 写进证书的 **SAN 扩展**。
- provenance 的 `builder.id` 也由此填充。
- **为什么不可伪造**：调用方仓库改不了 reusable workflow 的内容（它可被组织集中管控）；
  而 OIDC token 是 GitHub 在隔离环境里现签的、几分钟失效、构建脚本无法导出也无法伪造其
  `job_workflow_ref`。所以 `builder.id` 不是"自己声称"的，而是 GitHub 替你盖的章。

**环 4 — 签名 ↔ 不可抵赖**：签名条目写进 Rekor 透明日志（append-only、公开可查）。
即使将来 Fulcio 短期证书过期，Rekor 的时间戳证明"签名发生在证书有效期内"，且任何人能
独立核验该条目存在、未被事后篡改。

---

## 5. 验证时这条链是怎么被逐环走通的

```bash
gh attestation verify ExampleApp.ipa \
  --repo <owner>/<repo> \
  --signer-workflow <owner>/<repo>/.github/workflows/build-sign-attest.yml
```

1. **环 1**：对本地 `.ipa` 算 sha256，据此从 GitHub/Sigstore 拉取摘要匹配的 attestation——
   产物对不上就没有 attestation 可拉。
2. **环 4 → 环 3**：校验 Sigstore 签名链（Fulcio 根）与 Rekor 透明日志条目，确认签名真实
   且被公开记录。
3. **环 3 断言**：`--signer-workflow` 强制要求证书 SAN（即 `job_workflow_ref`）**必须**等于
   那个 reusable workflow 引用。**这一行是验证的灵魂**——它把"任何不是经由我们 reusable
   workflow 产生的 attestation"全部拒之门外。绕过该 workflow 的构建，即使也调了 attest，
   SAN 对不上，验证失败。
4. 三环全过，退出码 0。

**一句话总结**：`.ipa` 的字节被 sha256 钉进一份声明，声明被 GitHub 现签的、绑定 reusable
workflow 身份的短期证书签名并存进透明日志；验证方用 `--signer-workflow` 反过来断言"这份
声明只可能由那个集中管控、不可篡改的 workflow 签出"——产物、流程、身份三者缺一不可。

---

## 6. 两条凭证线的厘清（容易混）

项目里有两处"短期、运行时签发"的凭证，恰好都短期，但走**两套完全独立**的信任基础设施，
服务不同目的：

| 凭证线 | 用途 | 来源 | 与 SLSA 的关系 |
|--------|------|------|----------------|
| **GitHub App 短期 token** | `match` clone 私有证书仓库 | `create-github-app-token`（App 私钥 + client-id 现签，约 1h 失效） | **无关**，纯 Apple 侧 |
| **OIDC token → Sigstore** | 签出生证明（provenance） | GitHub 在 runner 内现签的 `id-token`（几分钟失效，构建脚本无法导出） | **证据链环 3 的根** |

把它们分清，才能理解：**SLSA 的不可伪造性不依赖任何长期保管的密钥**，而是依赖
GitHub 运行时签发、绑定 workflow 身份的短期 OIDC token。这正是"签名材料构建任务不可窃取"
的落地——构建脚本碰不到、也伪造不出 `job_workflow_ref`。

---

## 7. 附：SBOM attestation（与 provenance 平行的第二份证明）

provenance 回答"**怎么构建的**"，SBOM 回答"**用了什么**"。两者绑定到**同一个 `.ipa` digest**、
走**同一套 OIDC + Sigstore + Rekor 签名**，但 predicate 不同，互补而非替代：

| | provenance | SBOM |
|---|---|---|
| predicateType | `https://slsa.dev/provenance/v1` | `https://spdx.dev/Document`（SPDX） |
| 钉住什么 | `resolvedDependencies`（源码 git commit）、构建流程、签发身份 | 具体依赖包清单 |
| 本项目里的内容 | 见第 2 节 | Syft 扫到的 `Gemfile.lock`（fastlane 工具链）；app 无第三方运行时依赖，故产物成分维度近乎空 |

**生成方式**（见 `build-sign-attest.yml`，紧接 provenance 之后、上传之前，保持"先 attest 再分发"）：

1. `anchore/sbom-action`（Syft）扫仓库依赖来源 → 输出 `build/ExampleApp.sbom.spdx.json`；
2. `actions/attest`（通过 `sbom-path` 输入吃 SPDX）把它 attest 到 `.ipa`，复用 job 已有的 `id-token: write` + `attestations: write`。

> 注：早先用的 `actions/attest-sbom` 已被 GitHub 废弃，现已迁移到通用的 `actions/attest`——
> 后者同样提供 `sbom-path` 输入、自动识别 SPDX/CycloneDX，故参数原样不变。

**验证**（按 predicate 类型过滤；不加 `--predicate-type` 则列出该 `.ipa` 的全部 attestation）：

```bash
gh attestation verify ExampleApp.ipa \
  --repo <owner>/<repo> \
  --predicate-type https://spdx.dev/Document \
  --signer-workflow <owner>/<repo>/.github/workflows/build-sign-attest.yml
```

> ⚠️ **SBOM 的语义边界**：本项目 app 无 SPM/CocoaPods/Carthage 依赖、只链接 Apple 系统 framework
> （系统库通常不进 SBOM），所以"产物成分"维度近乎空；SBOM 的实际内容主要是**构建工具链**
> （`Gemfile.lock`）。将来引入 SPM 依赖时，Syft 会自动从 `Package.resolved` 把它们纳入。
