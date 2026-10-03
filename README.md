# dsh-toolkit

**DeepSeek Harness（DSH）运维工具箱** —— 把「升级后自检、插件兼容性预检、缺失能力补丁」三件套固化成一键可跑的工具与文档。

> 起因：一次桌面端自动升级把已装插件**静默打废**（插件看着装上了，MCP 工具列表却始终为空），
> 排查花了很久才定位到「精确 pin 的 peer 依赖与运行时失配」。这类问题不该靠人肉记住，
> 于是把自检、预检、补丁与调研沉淀为本仓库。

---

## 目录

| 目录 | 内容 |
|---|---|
| [`dsh-maintenance/`](./dsh-maintenance) | 升级后自检脚本、维护手册、`dsh-cost-meter` 账号登录态余额补丁（含幂等打补丁 / 回滚 / 端到端验证） |
| [`compat-check/`](./compat-check) | DSH 插件 × 宿主 **兼容性预检工具**（纯 PowerShell 实现 semver 判定）与 MCP 握手自测 |
| [`ecosystem-survey/`](./ecosystem-survey) | DSH 社区插件目录**全量调研**（4382 条）与选型报告 |

---

## 1. dsh-maintenance —— 升级后自检 + 缺失能力补丁

### 1.1 升级自检

```powershell
pwsh -File ./dsh-maintenance/check-after-upgrade.ps1
```

比对**桌面运行时版本**与**全局 CLI 版本**是否一致，读出 profile 里**实际安装**的插件版本，
再逐项核验 peer 兼容性。退出码约定：`0` 通过 / `1` 存在真不兼容 / `3` 元数据没拉到（**不得当通过**）。

> 真实事故：桌面端从 `0.2.0-rc.1` 升到 `rc.2`，而某插件装的是 `rc.1` 且 peer 是**精确 pin**，
> 于是被运行时拒绝加载。表现为「插件已安装、功能不生效」——自检脚本能把这种情况直接指出来。

### 1.2 `dsh-cost-meter` 官方余额：账号登录态补丁

**症状**：费用插件侧边栏「官方余额」恒为空。

**根因**：插件只实现了「开放平台 API Key」这一条取余额路径（`Authorization: Bearer <KEY>`），
而本机是**用账号登录**的（请求带 `x-dsh-auth-token`），凭据库里根本没有 `DEEPSEEK_API_KEY`，
于是走进 `apiKeyMissing` 软失败分支，余额行整体不渲染。

**关键发现**：同一个账号 token 本来就能查余额，只是**请求头不同**。

| 请求 | 结果 |
|---|---|
| `GET api.deepseek.com/user/balance` + `x-dsh-auth-token` | **200** ✅ |
| `GET api.deepseek.com/user/balance` + `Authorization: Bearer`（账号 token） | 401 ❌（它不是 API Key） |

**补丁做了什么**：只改 `queryBalance`，新增账号 token 回退分支——
**有 API Key 走 Bearer，没有则回退账号 token**。API Key 用户行为完全不变。
令牌只在签发来源与目标 origin 一致时返回，**不会外发到别的主机**。

```powershell
node ./dsh-maintenance/cost-meter-account-balance/apply-account-balance-patch.mjs --check  # 看状态
node ./dsh-maintenance/cost-meter-account-balance/apply-account-balance-patch.mjs          # 幂等重打
node ./dsh-maintenance/cost-meter-account-balance/verify-balance-patch.mjs                 # 端到端验证
node ./dsh-maintenance/cost-meter-account-balance/apply-account-balance-patch.mjs --revert # 还原
```

脚本对锚点做**唯一性检查**：插件升级导致源码结构一变就 FATAL 退出，**不会静默改错**。
验证脚本不是照抄逻辑，而是**从磁盘上真实的 `lib/index.js` 里逐字抽出函数**再断言。

> 上游一旦支持账号登录态，本补丁即可删除（`--revert` + 更新插件）。

### 1.3 `asar-probe` —— 读 app.asar 里的内置包源码

DSH 大量内置包**不在 `node_modules`**，而是打包在桌面端的 `resources/app.asar` 内，
普通 grep 看不到。该探针可**只读**列出/读取其中的文件（不解包、不写盘）。

```powershell
$env:DSH_ASAR = "$env:LOCALAPPDATA\Programs\DeepSeek Harness\resources\app.asar"
node ./dsh-maintenance/asar-probe/probe.mjs list "README"     # 参数是正则，按路径匹配
node ./dsh-maintenance/asar-probe/probe.mjs read "/dsh/node_modules/@deepseek-ai/<pkg>/README.md"
```

> `list` 的第三个参数是**正则**而非文件名；命中为空时只打印表头与文件总数（属正常，不是报错）。

---

## 2. compat-check —— 插件兼容性预检

```powershell
pwsh -File ./compat-check/check-plugin-compat.ps1 -Help                      # 看用法与退出码
pwsh -File ./compat-check/check-plugin-compat.ps1 -Specs 'dshmarket@1.38.1'  # 查指定候选
pwsh -File ./compat-check/check-plugin-compat.ps1 -Profile "$env:USERPROFILE\.dsh\profiles\desktop"
```

- 自动识别本机 Harness 版本与全部 `@deepseek-ai/*` 提供版本
- 逐个检查候选插件 `peerDependencies`（重点 `@deepseek-ai/*`）与 `engines.node`
- **纯 PowerShell 实现 semver 判定**，预发布版本窗口规则**与 node-semver 对照验证过**
- 已装插件直接读磁盘、npm 元数据本地缓存，**无网络也能判定大部分场景**
- 退出码可接入自动化门禁：**0** 通过 / **1** 不兼容（禁止更新）/ **3** 无法核实（**不得当通过**）

> 为什么需要它：DSH 真实的安装门**只检查** `peerDependencies` 里的 `@deepseek-ai/dsh*` 条目，
> 且**没有 aboveMax 宽容**；而社区某些市场工具的口径偏乐观。口径不一致 ⇒ 必须自己有一把尺子。

`mcp-handshake-test.cjs` 则独立验证一个 MCP stdio server 能否正常 `initialize` + `tools/list`，
只做握手不调用业务工具。路径走环境变量（`WB_MCP_SERVER` / `WB_COMMAND` / `NODE_BIN`）。

---

## 3. ecosystem-survey —— 插件生态全量调研

对 DSH 社区插件目录**全量 4382 条**做兼容性判定与选型分析：

- 判定函数**直接调用** `dshmarket` 自带的 `manifestFacts` + `deriveHostCompatibility`，**未自行重写规则**
- 数据源为每个包的 npm `latest` manifest（`peerDependencies` / `engines`）
- 4382 条中 **2253 条有 npm 包**可探测，**2129 条无 npm 包**（装不了，单独列 sheet）
- 报告含**口径溯源**：区分「dshmarket 口径」与「DSH 真实安装门口径」，并明确标注前者偏乐观

产物：`DSH插件选型报告.md`（结论 / 方法 / 总量 / 明细）、`DSH插件兼容性全量清单.xlsx`、`summary.json`。

---

## 环境要求

- Windows + PowerShell 5.1+（或 PowerShell 7）
- Node.js（asar 探针、MCP 握手自测、余额补丁脚本）
- 已安装 DeepSeek Harness 桌面端（自检与探针需要）

---

## 许可

[MIT](./LICENSE)

## 说明

- 仓库内脚本**不含任何凭据**：令牌一律在运行时从宿主凭据库读取，不落盘、不打印。
- 所有机器相关路径走**环境变量或按当前用户推导**，不绑定到某一台机器。
