#!/usr/bin/env node
/**
 * 验证「官方余额账号登录态补丁」是否真的通了。
 *
 * 做法：从**磁盘上真实的** dsh-cost-meter/lib/index.js 里逐字抽出
 * balanceEndpoint / accountBalanceHeaders / queryBalance 三个函数，
 * 注入桩依赖后真实调用一次 queryBalance（会真的出网打 api.deepseek.com），
 * 断言：
 *   1. 没有 API Key 时会走账号回退，且 resolveToken 被要求解析
 *      https://api.deepseek.com 这个 origin；
 *   2. 返回的余额结构里有 currency / totalBalance；
 *   3. 账号服务完全缺失时仍然是软失败的 apiKeyMissing（不会伪装成 0 余额）；
 *   4. 非官方端点仍被 balanceEndpoint 拒绝（令牌不会发去别的主机）。
 *
 * 用法：node verify-balance-patch.mjs
 * 退出码：0 全部通过；1 有断言失败；2 环境/锚点问题。
 * 注意：只打印币种与金额，不打印 token。
 */

import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { pathToFileURL } from 'node:url'

const dshHome = process.env.DSH_HOME ?? path.join(os.homedir(), '.dsh')
const profile = process.argv.find(a => a.startsWith('--profile='))?.slice('--profile='.length) ?? 'desktop'
const entry = path.join(dshHome, 'profiles', profile, 'node_modules', 'dsh-cost-meter', 'lib', 'index.js')

if (!fs.existsSync(entry)) {
  console.error(`[FATAL] 找不到 ${entry}`)
  process.exit(2)
}

const src = fs.readFileSync(entry, 'utf8')
if (!src.includes('本地补丁(2026-09-29')) {
  console.error('[FAIL] 该文件没有打补丁标记 —— 先跑 apply-account-balance-patch.mjs')
  process.exit(1)
}

/** 按大括号配平从源码里切出一个函数（本文件里没有会干扰配平的字符串/注释）。 */
function extract(fnName) {
  const start = src.search(new RegExp(`(?:async )?function ${fnName}\\(`))
  if (start < 0) throw new Error(`找不到函数 ${fnName}`)
  const braceStart = src.indexOf('{', start)
  let depth = 0
  for (let i = braceStart; i < src.length; i += 1) {
    if (src[i] === '{') depth += 1
    else if (src[i] === '}') {
      depth -= 1
      if (depth === 0) return src.slice(start, i + 1)
    }
  }
  throw new Error(`函数 ${fnName} 大括号不配平`)
}

let mod
try {
  const generated = [
    "const tmsg = (locale, key) => '[' + locale + '] ' + key",
    'const credentialRef = value => value',
    'const pickBalanceInfo = infos => Array.isArray(infos) && infos.length > 0 ? infos[0] : undefined',
    'const fetchWithRetry = (url, init) => fetch(url, init)',
    '',
    extract('balanceEndpoint'),
    '',
    extract('accountBalanceHeaders'),
    '',
    extract('queryBalance'),
    '',
    'export { balanceEndpoint, accountBalanceHeaders, queryBalance }',
  ].join('\n')
  const tmp = path.join(os.tmpdir(), `cost-meter-balance-verify-${process.pid}.mjs`)
  fs.writeFileSync(tmp, generated)
  mod = await import(pathToFileURL(tmp).href)
  fs.rmSync(tmp, { force: true })
} catch (error) {
  console.error('[FATAL] 无法加载补丁函数：', error.message)
  process.exit(2)
}

let failures = 0
const check = (ok, label, detail = '') => {
  console.log(`${ok ? '[PASS]' : '[FAIL]'} ${label}${detail ? ' — ' + detail : ''}`)
  if (!ok) failures += 1
}

// 1) 非官方端点守卫
check(mod.balanceEndpoint('https://evil.example.com') === null, '非官方端点被拒绝')
check(mod.balanceEndpoint('https://api.deepseek.com/v1') === 'https://api.deepseek.com/user/balance', '官方端点(含 /v1 后缀)归一化正确')

// 2) 账号回退真实出网
const yamlPath = path.join(dshHome, '.credentials.yaml')
if (!fs.existsSync(yamlPath)) {
  console.error('[FATAL] 找不到凭据库', yamlPath)
  process.exit(2)
}
const token = fs.readFileSync(yamlPath, 'utf8')
  .match(/deepseek-account-platform\/default:[\s\S]*?token:\s*(\S+)/)?.[1]
if (!token) {
  console.log('[SKIP] 本机没有 deepseek-account-platform/default 账号令牌（可能用 API Key 登录），跳过出网断言')
} else {
  const seen = []
  const ctx = {
    get(name) {
      if (name === 'settings') return { get: () => undefined }
      if (name === 'credentials') return undefined
      if (name === 'deepseekAccount') {
        return { async resolveToken(url) { seen.push(url); return url === 'https://api.deepseek.com' ? token : undefined } }
      }
      return undefined
    },
  }
  try {
    const result = await mod.queryBalance(ctx, 'zh', undefined)
    check(seen.length === 1 && seen[0] === 'https://api.deepseek.com', 'resolveToken 被要求解析官方 origin', seen.join(','))
    check(typeof result?.currency === 'string' && Number.isFinite(result?.totalBalance), '拿到余额结构', JSON.stringify(result))
    check(!JSON.stringify(result).includes(token), '返回结构不含令牌')
  } catch (error) {
    check(false, '账号回退取余额', error.message)
  }

  // 3) 账号服务缺失 -> 软失败 apiKeyMissing（绝不伪装成 0 余额）
  try {
    await mod.queryBalance({ get: () => undefined }, 'zh', undefined)
    check(false, '未登录时应抛错')
  } catch (error) {
    check(error?.soft === true && /apiKeyMissing/.test(error.message), '未登录时软失败 apiKeyMissing', error.message)
  }
}

console.log('')
console.log(failures === 0 ? '[OK] 全部通过' : `[FAIL] ${failures} 项未通过`)
// 不用 process.exit()：出网后 undici 仍持有 keep-alive 连接，
// 在 Windows 上强退会触发 libuv 断言（!(handle->flags & UV_HANDLE_CLOSING)）。
process.exitCode = failures === 0 ? 0 : 1
