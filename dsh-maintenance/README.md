# DSH 维护手册（本机固化版）

> 适用机器：`<USER_HOME>`，桌面版运行时目录 `%LOCALAPPDATA%\Programs\DeepSeek Harness`
> 最后更新：2026-09-29

## 0. 一句话规则

**每次桌面端自动升级后，跑一次自检；装任何插件都带版本号；插件装完要重启桌面端。**
**升级/重装插件后还要重打本地代码补丁（见第 7 节，脚本幂等）。**

## 1. 升级后自检（必须）

```powershell
pwsh -File "<REPO>/dsh-maintenance\check-after-upgrade.ps1"
```

它做的事：
1. 比对 **桌面运行时版本**（注册表 `DeepSeek Harness <ver>`）与 **全局 CLI 版本**（`dsh --version`）；不一致会提示先 `npm install -g @deepseek-ai/dsh@<桌面版本>`。
2. 读取 `~/.dsh/profiles/desktop/package.json` + `node_modules` 里**实际安装**的插件版本。
3. 调用官方兼容性预检 `..\.compat-check\check-plugin-compat.ps1` 逐项核验。
4. 对「官方包精确 prerelease pin」的**已知假阳性**给出说明（pin 与运行时相同即为正常）。

判读：
- `exit 0` → 通过（`[REVIEW]` 只是外部 peer 警告，可接受）
- `exit 1` → 有真不兼容项，按 FAIL 提示把该插件升/降到匹配运行时的版本
- `exit 3` → 元数据没拉到，网络恢复后重跑

## 2. 为什么必须做这件事（真实事故）

2026-09-29 桌面端自动从 `0.2.0-rc.1` 升到 `0.2.0-rc.2`，而 `@deepseek-ai/dsh-mcp-client` 装的是 `0.2.0-rc.1`，
它的 peer 是**精确 pin**，于是在 rc.2 上被「启动时拒绝」——表现为插件看着装了、MCP 工具列表却始终为空。
同类风险存在于所有「精确 pin」插件：**运行时一变，它们就静默失效**。

## 3. 安装插件的正确姿势

- **桌面 profile（你在用的这个）只能通过 GUI / 插件市场安装**，CLI 会被 `rejectElectronProfile` 硬拒。
  入口：设置 → 插件市场（`dshmarket` 已装）。
- **务必带显式版本号**，例如 `dsh-my-context@0.1.5`。原因是 pnpm 的**发布年龄闸门**会把仅写 `@latest`
  的请求降级到"足够旧"的版本，而降级后的版本常常还是 0.1.x 世代 → 被 DSH 闸门二次拒绝。
- 装完**重启桌面端**才生效（bundle 补丁在启动时应用）。

## 4. 已知坑位速查

| 现象 | 原因 | 处理 |
|---|---|---|
| 插件装上了但功能不生效 | 运行时升级后 exact-pin peer 失配 | 把该插件升到与运行时同代版本（第 1 节自检可发现） |
| `dsh plugin add xxx@latest` 装出旧版本 | pnpm 发布年龄闸门（约 24h 窗口） | 显式钉版本，如 `xxx@1.2.3` |
| `ERR_PNPM_IGNORED_BUILDS` | 依赖带 postinstall 构建脚本，pnpm 默认拦截 | 看 `pnpm-workspace.yaml` 的 `allowBuilds` 占位项；确认脚本无害后置 `true`/`false`（本机 `protobufjs`、`@aiwayds/dsh-mcp-adapter` 已裁决） |
| GUI 说"该插件已安装"但其实是补丁行引用了包名 | 应用以「补丁行是否引用该包」判定 | 真装包（`pnpm --dir <profile> add <包>@<版本>`），或先删补丁行再走 GUI |
| 社区预检报 `harness provides X, outside range X`（X 完全相同） | 工具把 harness 版本剥掉 prerelease 再比对精确 pin | 假阳性，忽略 |
| 桌面端崩溃 / 起不来 | 升级切换、插件冲突 | 救援控制台 `dsh-boot-guard`（已装）；配置回滚用 `cordis.patch.yml.bak-*` |
| 费用插件「官方余额」一直空 | 插件只认开放平台 API Key，而本机是 **DeepSeek 账号登录**（凭据库里没有 `DEEPSEEK_API_KEY`） | 重打本地补丁（第 7 节）后**重启**；或改用 API Key 路径 |

## 5. 本机关键路径

| 用途 | 路径 |
|---|---|
| DSH 主目录 | `~/.dsh` |
| 桌面 profile | `~/.dsh/profiles/desktop`（`package.json` = 依赖与 bundles；`cordis.patch.yml` = 用户补丁层） |
| web profile（已清空，保留骨架） | `~/.dsh/profiles/web` |
| 补丁层备份 | `~/.dsh/profiles/desktop/cordis.patch.yml.bak-*`、`package.json.bak-mcp-*`、`pnpm-lock.yaml.bak-mcp-*` |
| 预检工具 | `<REPO>/compat-check\check-plugin-compat.ps1` |
| MCP 握手自测 | `<REPO>/compat-check\mcp-handshake-test.cjs` |
| 插件管理器日志 | `~/.dsh/profiles/desktop/.plugin-manager/logs/operation-*/pnpm.log` |
| **本地代码补丁目录** | `<REPO>/dsh-maintenance\cost-meter-account-balance` |
| 插件实体文件（会被 pnpm/升级覆盖） | `~/.dsh/profiles/desktop/node_modules/dsh-cost-meter` |
| app.asar 只读探针（读 DSH 内置包源码/README） | `<REPO>/dsh-maintenance\asar-probe\probe.mjs` |

## 6. 回滚配方

```powershell
# 回滚补丁层（token 优化前的原件）
Copy-Item "$env:USERPROFILE\.dsh\profiles\desktop\cordis.patch.yml.bak-before-token-tuning-20260929-201004" `
          "$env:USERPROFILE\.dsh\profiles\desktop\cordis.patch.yml" -Force

# 回滚依赖清单与锁（装 MCP 客户端之前的原件）
Copy-Item "$env:USERPROFILE\.dsh\profiles\desktop\package.json.bak-mcp-20260929-205236" `
          "$env:USERPROFILE\.dsh\profiles\desktop\package.json" -Force
```
（回滚后重启桌面端；如 `node_modules` 与新清单不符，在 profile 目录跑 `pnpm install`。）

## 7. 本地代码补丁（会被重装/升级覆盖，需重跑）

| 补丁 | 目录 | 触发重跑的场景 |
|---|---|---|
| `dsh-cost-meter` 官方余额支持账号登录态（`x-dsh-auth-token`） | `dsh-maintenance\cost-meter-account-balance` | 重装/更新该插件、profile 里 `pnpm install`、桌面端升级 |

```powershell
$dir = "<REPO>/dsh-maintenance\cost-meter-account-balance"
node "$dir\apply-account-balance-patch.mjs" --check     # 先看状态
node "$dir\apply-account-balance-patch.mjs"             # 幂等重打
node "$dir\verify-balance-patch.mjs"                    # 端到端验证（会出网一次）
node "$dir\apply-account-balance-patch.mjs" --revert    # 还原
```

要点：
- 改的是 `~/.dsh/profiles/desktop/node_modules/dsh-cost-meter/lib/index.js`，**HMR 不监听 node_modules，必须重启桌面端**才生效。
- 脚本对锚点做唯一性检查，插件升级后源码结构一变就 FATAL 退出，不会静默改错；此时按 `cost-meter-account-balance/README.md` 第 8 节的建议走上游 issue。
- 详细根因、实测证据与上游建议见 `dsh-maintenance\cost-meter-account-balance\README.md`。
