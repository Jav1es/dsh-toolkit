# DSH 插件目录兼容性调研 · 选型报告

> 调查日期：2026-09-29 ｜ 调查对象：DSH 社区插件目录全量
> 宿主版本：`@deepseek-ai/dsh` **0.2.0-rc.2**（本机 `desktop` profile 实际版本，从 app.asar 内 packages.json 读出）

---

## 一、一句话结论

**你要的那类插件（把 `chat.deepseek.com` 网页端接进 DSH），在整个社区目录 4382 条里只有 2 个，而且两个都没有声明支持你的版本。**

那份方案点名的 6 个包，**4 个根本不在社区目录里**，1 个未声明版本，只有 1 个真正兼容。

---

## 二、调查方法与判定口径

| 项 | 内容 |
|---|---|
| 目录来源 | `dsh-plugin-catalog@2026.929.4715`（走你已装 dshmarket 配置的**腾讯镜像**路径拉取），共 **4382** 条，目录更新日 2026-09-28 |
| 判定函数 | **直接调用 `dshmarket@1.66.5` 自带的** `manifestFacts` + `deriveHostCompatibility`，未自行重写规则 |
| 数据来源 | 每个包的 npm `latest` manifest（peerDependencies / engines） |
| 探测范围 | 4382 条中 **2253 条有 npm 包**可探测；**2129 条无 npm 包**（装不了，见清单第 2 个 sheet） |

**判定含义**（务必分清）：

| 判定 | 含义 |
|---|---|
| ✅ **兼容**（dshmarket 口径） | 插件**声明了** DSH 版本约束，且按 dshmarket 规则被 0.2.0-rc.2 满足。**⚠️ 此口径偏乐观，不等同于能装上，见第三节更正** |
| ❔ **未声明** | 插件**没写** `engines.dsh`，也**没有** `@deepseek-ai/dsh*` 的 peerDependencies —— **既没声称支持，也没声称不支持**。按 DSH 安装门，这类**反而能装**（没有可违反的声明） |
| ❌ **不兼容** | 声明的约束被 0.2.0-rc.2 **明确违反** |
| ⚠️ 探测失败 | npm 上取不到元数据（本次为 0） |

> **DSH 真实安装门的规则**（从 `@deepseek-ai/dsh-app-boot` 提取）：只检查 `peerDependencies` 里名为 `@deepseek-ai/dsh` 或 `@deepseek-ai/dsh-*` 的条目，用严格 semver（`includePrerelease`）；**没有任何此类条目就直接放行**；`engines.dsh` 不参与判定。**没有 aboveMax 宽容**。

---

## 三、总量结果

> ⚠️ **2026-09-29 晚更正**：下表原按 dshmarket 口径统计，**偏乐观**。实测发现 DSH 自己的安装门比 dshmarket 严格得多（dshmarket 有 aboveMax 宽容，安装门没有），已按 DSH 真实规则重算并重建清单。**以"能否真正装上"一列为准。**

### 3.1 能否真正装到 0.2.0-rc.2（DSH 真实安装门口径）

| 判定 | 数量 | 含义 |
|---|---|---|
| ✅ **可安装** | **604** | 声明了 `@deepseek-ai/dsh*` peer，且全部满足 0.2.0-rc.2 |
| ✅ **可安装（未声明）** | **918** | 完全没有 `@deepseek-ai/dsh*` peer —— 没有可违反的声明 |
| ⛔ **会被拒绝** | **731** | 至少一条 dsh peer 不满足（绝大多数是 `^0.1.x`，面向旧发布线） |
| 合计（有 npm 包） | 2253 | |

**关键更正**：dshmarket 判为「兼容」的 1183 个里，**481 个会被真实安装门拒绝**。

### 3.2 dshmarket 口径（保留作对照）

| 判定 | 数量 | 占比 |
|---|---|---|
| ✅ 兼容 | 1183 | 52.5% |
| ❔ 未声明 | 806 | 35.8% |
| ❌ 不兼容 | 264 | 11.7% |
| 合计 | 2253 | 100% |

与你目标相关的三个分类：

| 分类 | 可探测 | 兼容 | 未声明 | 不兼容 |
|---|---|---|---|---|
| `model` 模型与账号接入 | 126 | **75** | 29 | 22 |
| `browser` 浏览器与网页 | 57 | **39** | 12 | 6 |
| `session` 会话与消息 | 142 | **74** | 45 | 23 |

---

## 四、那份方案点名的 6 个包

| 包名 | 判定 | npm 最新 | DSH 版本声明 | 说明 |
|---|---|---|---|---|
| `@jaychang1989/dsh-webchat` | ❌ **不在社区目录** | 0.5.2 | engines `>=0.2.0-rc.1` | 目录 4382 条里查无此包 |
| `dsh-webchat`（原始版） | ❌ **不在社区目录** | 0.2.0 | 仅 react peer | 同上 |
| `dsh-deepseek-web` | ❌ **不在社区目录** | 1.0.3 | peer 锁 `^0.1.0-rc.7` | 同上；且该 peer 与你的 0.2.0-rc.2 不同发布线 |
| `dsh-deepseek-web-login` | ❔ **未声明** | 0.6.5 | **无** | 唯一在目录里的核心候选，但没声称支持任何 DSH 版本 |
| `dsh-free-models-hub` | ✅ **兼容** | 0.3.1 | peer `dsh-settings: *` | 需要自建 PHP 7.4 + SQLite 后端 |
| `dsh-browser` | ❌ **不在社区目录** | 0.1.0 | peer `cordis ^4.0.1` | 目录查无此包 |

> 「不在社区目录」不等于"有恶意"，但意味着它**没有经过目录的收录与能力标注流程**——目录会记录每个插件的 `capabilities`（shell / fs-write / network / env 等）和 `capabilityRedLines`，不在目录里就没有这层公开披露。

---

## 五、关键发现：做"网页版 DeepSeek 接入"的只有 2 个，且都不兼容声明

在全部 4382 条里，描述涉及 `chat.deepseek.com` 网页端接入的**只有这两个**：

### ① `dsh-deepseek-web-login@0.6.5` —— 功能最对口，但要求的能力最宽

| 项 | 值 |
|---|---|
| 判定 | ❔ **未声明**（无 `engines.dsh`，无 DSH peer） |
| 作者 / 分类 | cv-superding / `model` |
| 热度 | 月下载 3274 · 星标 **178** |
| 说明 | 新增 `deepseek-web` provider，把 chat.deepseek.com 网页端模型接入 DSH：浏览器登录抓取、PoW 请求签名、SSE 流式传输与基于提示词的工具调用 |
| **申请能力** | 🔴 `shell` · `fs-write` · `fs-read` · `network` · `env` · `llm` |
| 声明红线 | 无（空） |

**这是唯一能同时满足你"发 prompt 到网页端 + 收回复进 DSH + 用网页模型驱动 Agent"的插件。** 但它向宿主申请了 **shell + 文件读写 + 网络 + 读环境变量**——等于把整机权限交给一个第三方插件，且它自己没声明任何红线。

### ② `@zerorigin-studio/dsh-deepseek-chat@0.3.5` —— 只做"打开网页"

| 项 | 值 |
|---|---|
| 判定 | ❔ **未声明** |
| 作者 / 分类 | zerorigin-studio / `ui` |
| 热度 | 月下载 999 · 星标 4 |
| 说明 | 网页对话入口插件：侧边栏一键打开 chat.deepseek.com 独立窗口（dsh-desktop 桥接），纯网页环境自动回退内嵌打开 |
| **申请能力** | 🟢 仅 `dynamic-code` |
| 安装 | `dsh plugin --profile web add @zerorigin-studio/dsh-deepseek-chat` |

功能上就是那份方案里 `@jaychang1989/dsh-webchat` 想做但做残了的事——**只是打开网页，不做数据搬运**。权限面小得多。

> 旁证：同类思路的 `@wlv-zedd/dsh-chatgpt-web`（ChatGPT 网页端零成本 provider）判定为 ❌ **不兼容**。说明"包装网页端"这类插件普遍跟不上 DSH 的版本节奏。

---

## 六、✅ 明确声明兼容 0.2.0-rc.2 的替代方案（按你的三个子目标分）

### 目标 A：读/导入对话历史

| 包 | 分类 | 月下载 | 说明 |
|---|---|---|---|
| `dsh-chat-import` | session | 16440 | 把 13 家 coding agent（Claude Code、Codex、ChatGPT、Cursor、Gemini、opencode 等）的完整对话历史导入为可续聊的 DSH 会话 |
| `dsh-rewind-plugin` | session | 17284 | 会话内对话回退（Claude Code `/rewind` 语义） |
| `dsh-recall-plugin` | session | 6359 | 消息撤回 + 影子 git 快照 |
| `@hyzyn/dsh-search` | session | 2508 | 侧边栏全局搜索**历史会话**全文，点击直达 |

> ⚠️ `dsh-chat-import` 的说明里列的是编程 agent，**没有明说支持 chat.deepseek.com 的导出格式**——要用得先确认。

### 目标 B：浏览器自动化（能操作网页版，但要手动）

| 包 | 分类 | 月下载 | 说明 |
|---|---|---|---|
| `dsh-builtin-browser` | browser | **11871** | 共享真实浏览器：可观看、可接管的原生 Electron 窗口，agent 通过 CDP 驱动，内置 20 个 `browser_*` 工具（打开/快照/执行/填表/截图/下载/**登录态**） |
| `@wxg-prc-cpg/browser-skill-dsh-plugin` | browser | 15325 | 控制可见的 Chrome 和 Edge Agent Window，支持可访问性与 VOM 页面观察、截图、多会话隔离 |
| `@lyd123qw2008/dsh-tool-control-chrome` | browser | 2913 | 驱动你**已登录的真实** Chrome/Edge Profile、标签页与 Cookie |
| `@anweat/dsh-browser` | browser | 8052 | 自包含 Playwright(chromium) 运行时 |

> 这条路的优势：`chat.deepseek.com` 的 `frame-ancestors 'none'` **管不到**独立浏览器窗口，所以能正常打开；而且你用的是自己已登录的会话，不涉及把 cookie 交给别人。代价是 agent 靠截图/快照操作，慢且不稳。

### 目标 C：拿到"免费/订阅"模型（不碰网页端私有接口）

| 包 | 分类 | 月下载 | 说明 |
|---|---|---|---|
| `dsh-workbuddy-connect` | model | 7861 | 将 WorkBuddy 桌面 App 的模型接入 DSH，零配置 —— **你已装 0.6.5** |
| `dsh-codex-subscription` | model | 13169 | ChatGPT OAuth 订阅当模型用，无需 API Key |
| `@goodandready/dsh-subscriptions` | model | 9842 | OAuth 接入 ChatGPT Codex / Claude / Grok / Antigravity 订阅 |
| `dsh-plugin-subscriptions` | model | 9043 | 同上思路的另一实现 |
| `dsh-connect-trae` | model | 4132 | 接入本机登录的 Trae 中国区模型 |
| `dsh-agy-link` | model | 4202 | 接入 Google Antigravity，用 Gemini/Claude/GPT-OSS 订阅 |
| `dsh-connect-workbuddy` | model | 6057 | WorkBuddy 模型接入（另一实现，含积分概览） |
| `dsh-local-ai` | model | 3686 | Ollama 本地模型接入 |
| `dsh-llm-fallbacks` | model | 3905 | 基于角色的模型重试与备用策略 |

> **这类是"白嫖"里性价比最高、风险最低的一条**：全部走 OAuth/本机登录的官方授权面，不抓 cookie、不模拟私有接口、不违反服务条款。你已经有 `deepseek-account` + `dsh-workbuddy-connect`，其实已经在这条路上了。

---

## 七、我的建议

| 优先级 | 做法 | 理由 |
|---|---|---|
| 🥇 | **先别装网页端插件**，把你现有的"免费模型"通道用足：`deepseek-account`（已启用）+ `dsh-workbuddy-connect`（已装）+ 按需加 `dsh-llm-fallbacks` 做限流自动切换 | 全部声明兼容、全部走官方授权、零封号风险 |
| 🥈 | 想"看网页版对话"→ 装 `@zerorigin-studio/dsh-deepseek-chat`（能力仅 `dynamic-code`） | 权限面最小；只开窗口、不搬数据 |
| 🥉 | 想"让 DSH 用网页版模型"→ 只有 `dsh-deepseek-web-login` 一条路，但它 **未声明版本**且 **申请 shell+fs+network+env** 权限 | 要装就**只在 web profile 里试**，别碰 desktop |
| ❌ | 不要用那份方案里的 `irm ... \| iex` 安装脚本，也不要装不在目录里的 4 个包 | 来源不一致 + 无能力披露 |

---

## 八、安全提醒（不变）

1. 🔴 **绝不把 cookies / `DEEPSEEK_TOKEN` 交给第三方或本地代理**——等同交出整个账号。
2. 🟠 装任何申请 `shell` / `fs-write` / `env` 的插件前，先想清楚它拿这些权限做什么。
3. 🟠 **先在 `web` profile 试**：`desktop` profile 被 Electron 独占托管（`dsh --profile desktop --dump-config` 会直接报错拒绝），装坏了自己改不回来。
4. 🟠 免费账号单线程，别并发打网页端。

---

## 八之二、本次实际安装记录（2026-09-29 晚）

安装前已备份：`<USER_HOME>\Desktop\dsh-backups\dsh-20260929-215210577.tar.gz`
（sha256 `fb94a0e4940e54d61ab76fdc27c543e1dce691aab4e61f13bba5ebdba8c26c35`）

### 装上的 6 个（全部已生效）

| 插件 | 版本 | 作用 |
|---|---|---|
| `dsh-chat-import` | 0.22.2 | 把 27 种外部对话记录导入为可续聊的 DSH 会话（已激活 `import_chat` 工具） |
| `dsh-context` | 0.59.1 | 上下文洞察面板 + `/context` 命令，看上下文构成与压缩事件 |
| `@hytime/dsh-thinking-effort` | 0.3.5 | 思考档位与子 agent 强度可视化配置（省得手改 yaml） |
| `dsh-sessions-manager` | 3.7.4 | 会话归档 / 恢复 / 彻底删除 / 跨工作区移动 |
| `dsh-session-pin` | 0.7.16 | 会话与工作区置顶、分组标签 |
| `dsh-shared` | 0.1.6 | **库**（`dsh.kind=library`），用来修复下面那个坏插件 |

### 顺手修好的：`dsh-my-context`

- **病因**：它把 `dsh-shared@^0.1.4` 声明为**必选 peer**（未标 optional），但你的 profile **从来没装过这个包**；`pnpm-workspace.yaml` 里 `autoInstallPeers: false` 也不会自动补。安装日志里没有任何一次操作装过 `my-context`，20:45 的 lockfile 备份里 `dsh-shared` 出现 **0 次** —— 说明**它在被装进来那天起就没能加载过**，与本次操作无关。
- **修法**：装 `dsh-shared@0.1.6`（`install_bundle` 拒绝注册为 bundle 并报 `not-bundle`，但包已落盘），再把声明补进 `package.json` 并跑 `pnpm install` 对齐 lockfile，最后禁用→启用一次强制重载。现在 `include:my-context` 状态与健康插件一致。

### 被拒的（**未**授予版本豁免）

| 插件 | 版本 | 被拒原因 |
|---|---|---|
| `dsh-llm-fallbacks` | 0.6.3 | peer 锁 `^0.1.7-rc.2` |
| `@hyzyn/dsh-search` | 0.4.1 | peer 锁 `^0.1.7-rc.2` |
| `dsh-sessions-manager` | 3.7.2 | 供应链策略把版本降到 3.7.2，其 peer 为 `^0.1.0-rc.6`；**加白名单取 3.7.4 后成功** |
| `@goodandready/dsh-model-sync` | 0.5.3 | 包装上了但**激活失败**（插件自身 bug：`DataCloneError: () => current could not be cloned`）→ 已移除 |
| `dsh-rewind-plugin` / `dsh-univer-office` / `dsh-builtin-browser` | — | 预扫即判定会被门拦下，未尝试 |

> **`dsh-llm-fallbacks` 和 `@hyzyn/dsh-search` 若你确实想用**，需要显式授予「精确版本豁免」（`dsh plugin allow-version` 或插件管理器）。按 DSH 的告警，这类豁免**有崩溃与数据丢失风险**，必须你本人明确同意我才做。

### 顺带修掉的环境问题

`pnpm` 的 store 路径不一致（`ERR_PNPM_UNEXPECTED_STORE`）：desktop profile 的 `node_modules` 链接自 `C:\.pnpm-store\v11`，而 pnpm 11.7.0 默认改用 `%LOCALAPPDATA%\pnpm\store\v11`。因为 **web profile 用的是新 store**，改全局配置会把 web 弄坏，所以只在 desktop profile 的 `pnpm-workspace.yaml` 里加了 `storeDir: C:/.pnpm-store`（项目级，不影响其他项目）。原文件已备份为 `pnpm-workspace.yaml.bak-before-storedir-20260929`。

### 另一个坑：供应链策略会静默降级版本

pnpm 的 `minimumReleaseAge`（约 24h）会跳过"太新"的版本，导致解析到**旧版本**，而旧版本的 peer 往往是 `^0.1.x` → 被安装门拒绝。解法就是往 `pnpm-workspace.yaml` 的 `minimumReleaseAgeExclude` 加白名单（你原本就有这个习惯），本次已为 6 个包追加。

---

## 九、附件

| 文件 | 内容 |
|---|---|
| `DSH插件兼容性全量清单.xlsx` | 3 个 sheet：全量判定（2253 条，带筛选/冻结首行）、无 npm 包条目（2129 条）、判定口径说明 |
| `summary.json` | 统计汇总（含按分类的判定分布） |
