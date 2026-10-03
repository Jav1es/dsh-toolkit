/**
 * app.asar 只读探针：列目录 / 读单个文件，用来查 DSH 内置包的源码与 README。
 *
 * 背景：`node_modules/@deepseek-ai/*` 大部分**不在 profile 里**，而是打包在
 * `%LOCALAPPDATA%\Programs\DeepSeek Harness\resources\app.asar` 内，
 * 普通 glob/grep 看不到。DSH 的运行时行为（provider id、settings 命名空间、
 * 服务名与方法签名）只能从这里读。
 *
 * 用法：
 *   node probe.mjs list "<正则>"            # 按路径列出匹配文件（含 size/offset）
 *   node probe.mjs read "/dsh/node_modules/@deepseek-ai/<pkg>/README.zh.md"
 *
 * app.asar 路径取自环境变量 DSH_ASAR，未设置时按桌面端默认安装位置推断，
 * 因此不绑定到某一台机器的用户名。
 *
 * 只读，不写、不解包、不校验完整性。
 */
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'

const DEFAULT_ASAR = path.join(
  process.env.LOCALAPPDATA ?? path.join(os.homedir(), 'AppData', 'Local'),
  'Programs', 'DeepSeek Harness', 'resources', 'app.asar',
)
const ASAR = process.env.DSH_ASAR ?? DEFAULT_ASAR
if (!fs.existsSync(ASAR)) {
  console.error(`app.asar 不存在：${ASAR}`)
  console.error('请设置环境变量 DSH_ASAR 指向实际路径。')
  process.exit(2)
}
const fd = fs.openSync(ASAR, 'r')
const head = Buffer.alloc(16)
fs.readSync(fd, head, 0, 16, 0)
const a = head.readUInt32LE(0)
const b = head.readUInt32LE(4)
const c = head.readUInt32LE(8)
const d = head.readUInt32LE(12)
console.log('u32@0,4,8,12 =', a, b, c, d)

const headerSize = b
const headerBuf = Buffer.alloc(headerSize)
fs.readSync(fd, headerBuf, 0, headerSize, 8)
let jsonText = headerBuf.toString('utf8')
const start = jsonText.indexOf('{')
const end = jsonText.lastIndexOf('}')
const header = JSON.parse(jsonText.slice(start, end + 1))
console.log('header parsed, dataOffset guess =', 8 + headerSize)

const mode = process.argv[2] ?? 'list'
const target = process.argv[3]

function walk(node, prefix, out) {
  for (const [name, val] of Object.entries(node.files ?? {})) {
    const p = prefix + '/' + name
    if (val.files) walk(val, p, out)
    else out.push([p, val])
  }
}
const all = []
walk(header, '', all)
console.log('total files:', all.length)

if (mode === 'list') {
  const re = new RegExp(target ?? '.', 'i')
  for (const [p, v] of all) if (re.test(p)) console.log(p, v.size, v.offset)
} else if (mode === 'read') {
  const dataOffset = 8 + headerSize
  const hit = all.find(([p]) => p === target)
  if (!hit) { console.log('NOT FOUND'); process.exit(1) }
  const [, v] = hit
  const buf = Buffer.alloc(v.size)
  fs.readSync(fd, buf, 0, v.size, dataOffset + Number(v.offset))
  process.stdout.write(buf.toString('utf8'))
}
fs.closeSync(fd)
