# dsh-cost-meter 官方余额：账号登录态补丁

> 机器：`<USER_HOME>`｜插件：`dsh-cost-meter@1.7.45`（npm 上的 latest）｜建立日期：2026-09-29

## 1. 症状

费用插件侧边栏的「官方余额」一直是空的（或悬停显示 `未配置 DeepSeek API Key`），
但本会话/当日费用、历史记录都正常。账本里 `storages/cost-meter/ledger.json` 的
`balanceRef` 恒为 `null` —— 说明**从未成功取到过一次官方余额**。

## 2. 根因

插件只实现了「开放平台 API Key」这一条取余额的路：

```
GET {baseURL}/user/balance
Authorization: Bearer <DEEPSEEK_API_KEY>      # llm-deepseek 设置段 + DSH 凭据库
```

而本机是**用 DeepSeek 账号登录**的（provider `deepseek-account`，模型请求带
`x-dsh-auth-token`）。`~/.dsh/.credentials.yaml` 里只有三条记录：

| 记录 | 用途 |
|---|---|
| `client-connection/browser-session` | 本机 Web 连接 |
| `deepseek-account-platform/device` | 设备标识 |
| `deepseek-account-platform/default` | **账号 token（issuer `https://platform.deepseek.com`）** |

**没有 `DEEPSEEK_API_KEY`**，`~/.dsh` 下也根本没有 `llm-deepseek` 设置段，
于是插件走 `apiKeyMissing` 这条软失败分支 → 余额行整体不渲染。

## 3. 关键发现：同一个 token 本来就能查余额

2026-09-29 实测（只读请求，未打印 token）：

| 请求 | 结果 |
|---|---|
| `GET https://api.deepseek.com/user/balance` + `x-dsh-auth-token: <账号 token>` | **200** ✅ |
| `GET https://api.deepseek.com/user/balance` + `Authorization: Bearer <账号 token>` | 401 ❌（它不是 API Key） |
| `GET https://platform.deepseek.com/api/v0/users/get_user_summary` + `x-dsh-auth-token` | 200 ✅（`normal_wallets` CNY 7.5989…） |

成功响应与插件期望的结构**完全一致**：

```json
{"is_available":true,
 "balance_infos":[{"currency":"CNY","total_balance":"7.42",
                   "granted_balance":"0.00","topped_up_balance":"7.42"}]}
```

即：`api.deepseek.com` 对账号 token 关的是 `Authorization: Bearer`，
`x-dsh-auth-token` 照样认。插件缺的只是这一步回退。

## 4. 补丁做了什么

只改 `lib/index.js` 的 `queryBalance`，其余一律不动：

1. 新增 `accountBalanceHeaders(ctx, endpoint)`：向宿主 `deepseekAccount` 服务要令牌
   （`resolveToken(origin)`，只在签发来源与目标 origin 一致时返回，令牌不会外发到别的主机）。
2. 原「无 API Key 直接抛 `apiKeyMissing`」的守卫改成：**有 Key 走 Bearer，没 Key 回退账号 token**。
3. 请求头从写死的 `{ authorization: Bearer <key> }` 改成上面构造好的 `authHeaders`。

结果：API Key 用户行为完全不变；账号登录用户拿到同一份余额。
令牌与模型推理同一把，**登录/退登、切号都自动跟随，无需手工维护**。

## 5. 生效方式

**必须重启桌面端**——DSH HMR 默认 `ignored: ["**/node_modules", ...]`，
`node_modules` 下的改动不会被热重载。重启后侧边栏出现 ¥ 余额，点击可手动刷新。

## 6. 固化脚本

```powershell
$dir = "<REPO>/dsh-maintenance\cost-meter-account-balance"

# 打补丁（幂等：已打过就只报告）
node "$dir\apply-account-balance-patch.mjs"

# 只看状态
node "$dir\apply-account-balance-patch.mjs" --check

# 还原到最近一次打补丁前
node "$dir\apply-account-balance-patch.mjs" --revert

# 端到端验证（会真的出网一次，只打印币种/金额，不打印 token）
node "$dir\verify-balance-patch.mjs"
```

**何时需要重跑**：任何会重新解包 `dsh-cost-meter` 的操作之后——

- 插件市场里更新/重装该插件；
- 在 `~/.dsh/profiles/desktop` 里跑 `pnpm install`；
- 桌面端自动升级后被替换（可挂在维护手册 §1 的升级自检后面）。

脚本对锚点做**唯一性检查**：插件升级导致源码结构变了会直接 FATAL 退出，
不会静默改错。备份：`lib/index.js.prepatch-<时间戳>`（每次打补丁）+ `lib/index.js.orig-<版本>`（出厂原件）。

## 7. 验证证据

```
[PASS] 非官方端点被拒绝
[PASS] 官方端点(含 /v1 后缀)归一化正确
[PASS] resolveToken 被要求解析官方 origin — https://api.deepseek.com
[PASS] 拿到余额结构 — {"currency":"CNY","totalBalance":7.33,"grantedBalance":0,"toppedUpBalance":7.33}
[PASS] 返回结构不含令牌
[PASS] 未登录时软失败 apiKeyMissing
```

验证脚本不是照抄逻辑，而是**从磁盘上真实的 `lib/index.js` 里逐字抽出这三个函数**再跑，
所以它断言的就是线上那份代码。

## 8. 长期方案（建议提给插件作者）

这是插件的功能缺口，不是本机配置问题。可提 issue：
「官方余额支持 DSH 账号登录态（`deepseek-account` / `x-dsh-auth-token`）」，
附上本文第 3 节的实测两张表。上游一旦支持，本补丁即可删除（`--revert` + 更新插件）。

另一个**无需补丁**的替代路径：在 <https://platform.deepseek.com> 建一个 API Key，
在 DSH「设置 → 模型 → DeepSeek」里填上，插件的官方余额就会按原设计工作
（同一账户、同一份余额，只是多一把 Key）。本补丁的价值在于**不要求你额外持有 API Key**。
