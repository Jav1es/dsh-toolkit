#!/usr/bin/env node
/**
 * dsh-cost-meter「官方余额」账号登录态补丁 —— 可重复执行的固化脚本。
 *
 * 背景（2026-09-29 实测）：
 *   DSH 桌面端用「DeepSeek 账号」登录时，模型走 provider `deepseek-account`
 *   （请求头 x-dsh-auth-token），凭据库里**没有** DEEPSEEK_API_KEY。
 *   而 dsh-cost-meter 的官方余额只认开放平台 API Key：
 *     GET https://api.deepseek.com/user/balance
 *     Authorization: Bearer <DEEPSEEK_API_KEY>
 *   拿不到 Key 就抛 apiKeyMissing，侧边栏余额永远不显示。
 *
 *   实测同一个账号 token 直接打该端点也能 200，返回结构完全一致：
 *     GET https://api.deepseek.com/user/balance
 *     x-dsh-auth-token: <账号 token>
 *     -> {"is_available":true,"balance_infos":[{"currency":"CNY",
 *         "total_balance":"7.42","granted_balance":"0.00","topped_up_balance":"7.42"}]}
 *   （把同一个 token 当 Bearer 用则 401，它不是 API Key。）
 *
 * 本脚本做的事：在 lib/index.js 的 queryBalance 里加一条回退——
 * 有 API Key 走原路；没有则用宿主 deepseekAccount 服务的 resolveToken()
 * 取账号 token，改发 x-dsh-auth-token。令牌与模型推理同一把，随登录/退登自动更新。
 *
 * 用法：
 *   node apply-account-balance-patch.mjs            # 打补丁（已打过则跳过）
 *   node apply-account-balance-patch.mjs --check    # 只看状态，不写
 *   node apply-account-balance-patch.mjs --revert   # 还原最近一次打补丁前的备份
 *
 * 何时需要重跑：任何会重新解包 dsh-cost-meter 的操作之后——插件市场里更新/重装
 * 该插件、在 profile 目录跑 pnpm install、桌面端升级后自检发现插件被替换。
 * 重跑是幂等的：已打过就只报告，不会重复插入。
 * 打完后必须**重启桌面端**才生效（HMR 默认忽略 **\/node_modules）。
 */

import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'

const MARKER = '本地补丁(2026-09-29,dsh-cost-meter 1.7.45)'

const args = new Set(process.argv.slice(2))
const mode = args.has('--check') ? 'check' : args.has('--revert') ? 'revert' : 'apply'

const profileArg = process.argv.find(a => a.startsWith('--profile='))?.slice('--profile='.length)
const dshHome = process.env.DSH_HOME ?? path.join(os.homedir(), '.dsh')
const profile = profileArg ?? 'desktop'
const entryPath = path.join(dshHome, 'profiles', profile, 'node_modules', 'dsh-cost-meter', 'lib', 'index.js')

if (!fs.existsSync(entryPath)) {
  console.error(`[FATAL] 找不到插件入口：${entryPath}`)
  console.error('        （profile 名不对，或该插件没装在这个 profile 里）')
  process.exit(2)
}

const original = fs.readFileSync(entryPath, 'utf8')
const patched = original.includes(MARKER)

if (mode === 'check') {
  const version = JSON.parse(fs.readFileSync(path.join(entryPath, '..', '..', 'package.json'), 'utf8')).version
  console.log(`插件版本   : ${version}`)
  console.log(`入口文件   : ${entryPath}`)
  console.log(`补丁状态   : ${patched ? '已打（含账号登录态回退）' : '未打（官方余额只认 API Key）'}`)
  console.log(`语法自检   : 请另跑  node --check "${entryPath}"`)
  process.exit(patched ? 0 : 1)
}

const backupDir = path.join(entryPath, '..')
const backups = () => fs.readdirSync(backupDir).filter(f => /^index\.js\.prepatch-\d{8}-\d{6}$/.test(f)).sort()

if (mode === 'revert') {
  const list = backups()
  if (list.length === 0) {
    console.error('[FATAL] 没有 prepatch-* 备份可还原；若只是要恢复出厂文件，请用 index.js.orig-* 备份。')
    process.exit(2)
  }
  const newest = list[list.length - 1]
  fs.copyFileSync(path.join(backupDir, newest), entryPath)
  console.log(`[OK] 已还原：${newest} -> lib/index.js`)
  console.log('     重启桌面端后生效。')
  process.exit(0)
}

if (patched) {
  console.log('[SKIP] 已经打过补丁，无需重复插入。')
  console.log(`       ${entryPath}`)
  process.exit(0)
}

// ── 补丁正文 ───────────────────────────────────────────────────────────────

const HELPER = `/**
 * 本地补丁(2026-09-29,dsh-cost-meter 1.7.45):账号登录态的官方余额鉴权头。
 *
 * 起因:DSH 官方账号登录(provider \`deepseek-account\`)不发开放平台 API Key,
 * 团队原先没有开放平台 Key 时官方余额永远取不到。实测 api.deepseek.com 的
 * /user/balance 同时接受账号 token 的 \`x-dsh-auth-token\` 头,返回的
 * balance_infos 结构与 API Key 完全一致,故在缺少 API Key 时回退到账号 token。
 * 令牌取自宿主 \`deepseekAccount\` 服务(与模型推理同一把,随登录/退登自动更新)。
 * resolveToken 只在令牌签发来源与目标 origin 一致时才返回,不会把令牌发去别处。
 * @param ctx - 宿主插件上下文。
 * @param endpoint - balanceEndpoint() 已校验过官方域名的余额端点。
 * @returns 鉴权请求头,或 null(未登录/账号服务不可用)。
 */
async function accountBalanceHeaders(ctx, endpoint) {
  const account = ctx.get('deepseekAccount')
  if (account === undefined || typeof account.resolveToken !== 'function') return null
  let origin = ''
  try { origin = new URL(endpoint).origin } catch { return null }
  try {
    const token = await account.resolveToken(origin)
    if (typeof token === 'string' && token.length > 0) return { 'x-dsh-auth-token': token }
  } catch {
    // 账号服务异常等同未登录:按软失败处理,不影响其他余额来源。
  }
  return null
}
`

const AUTH_BLOCK = [
  '  // 本地补丁(2026-09-29):有 API Key 走 Bearer,否则回退账号登录态 token。',
  '  const authHeaders = apiKey !== null && apiKey.length > 0',
  '    ? { authorization: `Bearer ${apiKey}` }',
  '    : await accountBalanceHeaders(ctx, endpoint)',
  '  if (authHeaders === null) {',
  '    // 守卫错误(不会自愈,重试无意义)标记 soft:与 coding-plans 的软失败同语义。',
  "    const err = new Error(tmsg(locale, 'apiKeyMissing', { env: apiKeyEnv }))",
  '    err.soft = true',
  '    throw err',
  '  }',
  '',
].join('\n')

/** 老的「无 Key 直接抛错」守卫 + 紧随其后的 endpoint 计算，整段换掉。 */
const OLD_GUARD = [
  '  if (apiKey === null && typeof process.env[apiKeyEnv] === \'string\') apiKey = process.env[apiKeyEnv]',
  '  if (apiKey === null || apiKey.length === 0) {',
  '    // 守卫错误(不会自愈,重试无意义)标记 soft:与 coding-plans 的软失败同语义。',
  "    const err = new Error(tmsg(locale, 'apiKeyMissing', { env: apiKeyEnv }))",
  '    err.soft = true',
  '    throw err',
  '  }',
  '  const endpoint = balanceEndpoint(baseURL)',
  '',
].join('\n')

const NEW_GUARD = [
  "  if (apiKey === null && typeof process.env[apiKeyEnv] === 'string') apiKey = process.env[apiKeyEnv]",
  '  const endpoint = balanceEndpoint(baseURL)',
  '',
].join('\n')

const OPS = [
  {
    label: '插入 accountBalanceHeaders 助手函数',
    find: '/**\n * 调用官方开放平台余额接口(GET {base}/user/balance)。',
    replace: HELPER + '\n/**\n * 调用官方开放平台余额接口(GET {base}/user/balance)。',
  },
  { label: '移除「无 API Key 直接抛错」守卫', find: OLD_GUARD, replace: NEW_GUARD },
  {
    label: '在请求前构造鉴权头',
    find: '  // 瞬时网络错误自动重试(issue #28 同一封装);非 2xx 状态仍按业务错误处理。',
    replace: AUTH_BLOCK + '  // 瞬时网络错误自动重试(issue #28 同一封装);非 2xx 状态仍按业务错误处理。',
  },
  {
    label: '请求改用构造好的鉴权头',
    find: '    headers: { authorization: `Bearer ${apiKey}` },',
    replace: '    headers: authHeaders,',
  },
]

let next = original
for (const op of OPS) {
  const first = next.indexOf(op.find)
  if (first < 0) {
    console.error(`[FATAL] 找不到锚点：${op.label}`)
    console.error('        该版本源码结构与脚本预期不符（多半是插件升级了）。')
    console.error('        请对照上游新版重写本脚本，不要手工瞎改。')
    process.exit(2)
  }
  if (next.indexOf(op.find, first + 1) >= 0) {
    console.error(`[FATAL] 锚点不唯一：${op.label}`)
    process.exit(2)
  }
  next = next.slice(0, first) + op.replace + next.slice(first + op.find.length)
}

// ── 备份 + 落盘 ───────────────────────────────────────────────────────────

const stamp = (() => {
  const now = new Date()
  const p2 = n => String(n).padStart(2, '0')
  return `${now.getFullYear()}${p2(now.getMonth() + 1)}${p2(now.getDate())}-${p2(now.getHours())}${p2(now.getMinutes())}${p2(now.getSeconds())}`
})()
const backupPath = path.join(backupDir, `index.js.prepatch-${stamp}`)
fs.writeFileSync(backupPath, original)

// 出厂原件备份（只在缺失时写，避免覆盖真正的原始文件）
const pkgVersion = JSON.parse(fs.readFileSync(path.join(backupDir, '..', 'package.json'), 'utf8')).version
const origBackup = path.join(backupDir, `index.js.orig-${pkgVersion}`)
if (!fs.existsSync(origBackup)) fs.writeFileSync(origBackup, original)

fs.writeFileSync(entryPath, next)

console.log(`[OK] 已打补丁：${entryPath}`)
console.log(`     打补丁前备份：${path.relative(process.cwd(), backupPath)}`)
console.log(`     出厂原件备份：${path.relative(process.cwd(), origBackup)}`)
console.log(`     插件版本：${pkgVersion}`)
console.log('')
console.log('接下来：')
console.log(`  1. 语法自检  node --check "${entryPath}"`)
console.log('  2. 重启桌面端（HMR 默认忽略 node_modules，不重启不生效）')
console.log('  3. 侧边栏官方余额应显示账号钱包余额（CNY），点击可手动刷新')
