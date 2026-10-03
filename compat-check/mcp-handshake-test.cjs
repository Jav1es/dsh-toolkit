// 独立验证 workbuddy-mcp 能否作为 MCP stdio server 正常握手并列出工具
// 只做 initialize + tools/list，不调用 run_workbuddy_task（不消耗积分）
const { spawn } = require('node:child_process');
const os = require('node:os');
const path = require('node:path');
const fs = require('node:fs');

// 路径全部走环境变量，避免绑定到某台机器的用户名。
//   WB_MCP_SERVER  MCP server 入口 .js（必填）
//   WB_COMMAND     被 MCP server 调用的后端命令（可选，按需传给子进程）
//   NODE_BIN       要使用的 node 可执行文件（默认当前进程的 node）
const NPM_GLOBAL = path.join(os.homedir(), 'AppData', 'Roaming', 'npm', 'node_modules');
const NODE = process.env.NODE_BIN || process.execPath;
const SERVER = process.env.WB_MCP_SERVER
  || path.join(NPM_GLOBAL, 'workbuddy-mcp', 'server.js');
const WB = process.env.WB_COMMAND
  || path.join(os.homedir(), 'AppData', 'Roaming', 'npm', 'codebuddy.cmd');

if (!fs.existsSync(SERVER)) {
  console.error(`MCP server 入口不存在：${SERVER}`);
  console.error('请用环境变量 WB_MCP_SERVER 指向实际路径。');
  process.exit(2);
}

const child = spawn(NODE, [SERVER], {
  env: { ...process.env, WB_COMMAND: WB },
  stdio: ['pipe', 'pipe', 'pipe'],
});

let out = '';
let err = '';
const seen = [];
child.stdout.on('data', (d) => {
  out += d.toString();
  for (const line of out.split('\n')) {
    const t = line.trim();
    if (!t || seen.includes(t)) continue;
    seen.push(t);
    try {
      const msg = JSON.parse(t);
      if (msg.id === 1) {
        console.log('initialize -> protocolVersion=' + (msg.result?.protocolVersion ?? 'n/a') +
          ' server=' + (msg.result?.serverInfo?.name ?? '?'));
        child.stdin.write(JSON.stringify({ jsonrpc: '2.0', method: 'notifications/initialized' }) + '\n');
        child.stdin.write(JSON.stringify({ jsonrpc: '2.0', id: 2, method: 'tools/list', params: {} }) + '\n');
      }
      if (msg.id === 2) {
        const tools = msg.result?.tools ?? [];
        console.log('tools/list -> ' + tools.length + ' 个工具:');
        for (const t of tools) console.log('   - ' + t.name + ' :: ' + String(t.description || '').slice(0, 70));
        child.kill();
        process.exit(0);
      }
      if (msg.error) console.log('ERROR from server: ' + JSON.stringify(msg.error));
    } catch { /* 非 JSON 行忽略 */ }
  }
});
child.stderr.on('data', (d) => { err += d.toString(); });

child.stdin.write(JSON.stringify({
  jsonrpc: '2.0', id: 1, method: 'initialize',
  params: { protocolVersion: '2025-06-18', capabilities: {}, clientInfo: { name: 'dsh-verify', version: '1.0.0' } },
}) + '\n');

setTimeout(() => {
  console.log('超时：未在 12 秒内完成 tools/list');
  if (err) console.log('stderr: ' + err.slice(0, 600));
  child.kill();
  process.exit(2);
}, 12000);
