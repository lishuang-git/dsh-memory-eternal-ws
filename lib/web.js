// 记忆核心 · 独立 Web server（UI 唯一真源）。
//
// 职责：
// - 静态服务 web/index.html + web/app.js（自包含 bundle，react 打入）
// - 同源挂载 /memory-eternal/api/*（复用 lib/api.js，与 DSH 内完全同一实现）
// - iframe 友好：不设 X-Frame-Options（DSH 宿主内嵌加载本页）
//
// 常驻方式：ensureWebServer() 探活 → 未活则 detached spawn 独立进程
// （DSH 插件激活 / MCP server 启动 / CLI 调用都会走它，实现「默认开启」）。
//
// 直接运行：node lib/web.js --port 7999 [--vault <dir>]

import http from 'node:http'
import { promises as fs, readFileSync } from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { createApi, API_PREFIX } from './api.js'
import { defaultVaultDir, configFilePath } from './capture-run.js'

const __dirname = path.dirname(fileURLToPath(import.meta.url))
const WEB_ROOT = path.join(__dirname, '..', 'web')
export const DEFAULT_WEB_PORT = Number(process.env.MEMORY_WEB_PORT) || 7999
const VERSION = (() => { try { return JSON.parse(readFileSync(path.join(__dirname, '..', 'package.json'), 'utf8')).version } catch { return '' } })()
process.env.MEMORY_ETERNAL_VERSION = VERSION

const MIME = { '.html': 'text/html; charset=utf-8', '.js': 'application/javascript; charset=utf-8', '.css': 'text/css; charset=utf-8' }

/** 读 DSH 写入的共享配置（含 vaultRelPath），供独立 web 按 ?cwd= 推导项目库。 */
function sharedConfig() {
  try { return JSON.parse(readFileSync(configFilePath(process.env), 'utf8')) || {} } catch { return {} }
}
function vaultRelPathOf() {
  const rel = String(sharedConfig().vaultRelPath || '.dsh/memory-vault')
  return rel.replace(/^[\\/]+/, '')
}

export function startWebServer({ port = DEFAULT_WEB_PORT, vaultRoot = defaultVaultDir(), host = '127.0.0.1' } = {}) {
  const handleApi = createApi({
    vaultDir: () => vaultRoot,
    vaultRoots: () => [{ name: '', root: vaultRoot }],
    // v0.8.0-ws：独立 web 也必须能按请求切库。iframe 面板是跨源页面，只能靠 ?cwd= 传目录；
    // 原版此处没有 resolver，于是「切换工作区后面板仍显示旧库」。
    resolveVault: (req, query) => {
      const q = query || new URL(req.url, 'http://localhost').searchParams
      const decode = (s) => { try { return decodeURIComponent(s) } catch { return s } }
      const vaultParam = String(q.get('vault') || '').trim()
      if (vaultParam) { try { return path.resolve(decode(vaultParam)) } catch { return path.resolve(vaultParam) } }
      const cwdParam = String(q.get('cwd') || '').trim()
      if (cwdParam) return path.join(path.resolve(decode(cwdParam)), vaultRelPathOf())
      return ''
    },
    // 读 DSH 写入的共享配置文件 → web 端与 DSH 设置同步（不同步修复）
    getSettings: () => { try { return JSON.parse(readFileSync(configFilePath(process.env), 'utf8')) } catch { return {} } },
    getDshInfo: () => ({ name: 'deepseek-harness', label: 'DeepSeek Harness（当前宿主）', installed: true, memoryRecallTool: true, autoCapture: true, autoRecall: true, vaultDir: vaultRoot, version: VERSION }),
  })

  const server = http.createServer(async (req, res) => {
    try {
      const url = new URL(req.url, 'http://localhost')
      const p = url.pathname
      if (p.startsWith(API_PREFIX)) return await handleApi(req, res)
      if (req.method !== 'GET' && req.method !== 'HEAD') {
        res.writeHead(405, { 'Content-Type': 'application/json' })
        return res.end(JSON.stringify({ ok: false, error: 'method not allowed' }))
      }
      if (p === '/' || p === '/index.html') {
        const buf = await fs.readFile(path.join(WEB_ROOT, 'index.html'))
        res.writeHead(200, { 'Content-Type': MIME['.html'], 'Cache-Control': 'no-store' })
        return res.end(buf)
      }
      if (p === '/app.js') {
        const buf = await fs.readFile(path.join(WEB_ROOT, 'app.js'))
        res.writeHead(200, { 'Content-Type': MIME['.js'], 'Cache-Control': 'no-store' })
        return res.end(buf)
      }
      res.writeHead(404, { 'Content-Type': 'application/json' })
      res.end(JSON.stringify({ ok: false, error: 'not found' }))
    } catch (error) {
      if (!res.headersSent) res.writeHead(500, { 'Content-Type': 'application/json' })
      res.end(JSON.stringify({ ok: false, error: String(error?.message || error) }))
    }
  })

  return new Promise((resolve, reject) => {
    server.once('error', reject)
    server.listen(port, host, () => {
      process.stderr.write(`[memory-eternal] web server on http://${host}:${port} (vault: ${vaultRoot})\n`)
      resolve({ server, port, host, url: `http://${host}:${port}` })
    })
  })
}

/** 探测某端口是否已是本项目的 web server（响应 /api/overview 且带 vaultDir 标记）。 */
export async function probeWebServer(port = DEFAULT_WEB_PORT, timeoutMs = 800, expectVault = '') {
  try {
    const res = await fetch(`http://127.0.0.1:${port}${API_PREFIX}/overview`, { signal: AbortSignal.timeout(timeoutMs) })
    if (!res.ok) return null
    const data = await res.json()
    if (!data || data.ok !== true || typeof data.vaultDir !== 'string') return null
    // v0.8.0-ws：探活必须校验「是不是我们期望的那个库」。旧实现只判断 vaultDir 是字符串，
    // 导致配置变更前启动的旧实例永久占位，切工作区后前端仍读旧库。
    if (expectVault) {
      const norm = (s) => String(s || '').replace(/[\\/]+$/, '').toLowerCase()
      if (norm(data.vaultDir) !== norm(expectVault)) return null
    }
    return data
  } catch {
    return null
  }
}

/**
 * 确保 web server 存活（默认开启的实现核心）。
 * 已活 → 直接返回 URL；未活 → detached spawn 独立进程并轮询探活。
 * 端口被非本项目进程占用时向后漂移（+1..+10）。
 * @returns {Promise<{url:string, port:number, spawned:boolean}>}
 */
export async function ensureWebServer({ port = DEFAULT_WEB_PORT, vaultRoot = defaultVaultDir(), spawnEnv = {}, totalTimeoutMs = 15000 } = {}) {
  // 探测可用端口：先找「已是我们的服务」的端口，再找空闲端口
  let target = port
  let found = null
  for (let p = port; p < port + 10; p++) {
    const alive = await probeWebServer(p, 800, vaultRoot)
    if (alive) { found = { url: `http://127.0.0.1:${p}`, port: p, spawned: false }; break }
    // 该端口不是「我们期望的那个库」的服务：连不上（空闲）就用它；否则端口漂移
    const isFree = await probeWebServer(p, 300, vaultRoot) === null && await isPortConnectable(p) === false
    if (isFree) { target = p; break }
    target = p + 1
  }
  if (found) return found

  // detached spawn：独立进程，父进程退出不影响（常驻）；stdio ignore 防阻塞
  const { spawn } = await import('node:child_process')
  const child = spawn(
    process.execPath,
    [path.join(__dirname, 'web.js'), '--port', String(target), '--vault', vaultRoot],
    { detached: true, stdio: 'ignore', env: { ...process.env, ...spawnEnv, MEMORY_VAULT_DIR: vaultRoot }, windowsHide: true },
  )
  child.unref()

  const deadline = Date.now() + totalTimeoutMs
  while (Date.now() < deadline) {
    await new Promise((r) => setTimeout(r, 400))
    const alive = await probeWebServer(target)
    if (alive) return { url: `http://127.0.0.1:${target}`, port: target, spawned: true }
  }
  throw new Error(`[memory-eternal] web server 未能在 ${totalTimeoutMs}ms 内就绪 (port ${target})`)
}

async function isPortConnectable(port) {
  const net = await import('node:net')
  return new Promise((resolve) => {
    const s = new net.Socket()
    s.setTimeout(300)
    s.once('connect', () => { s.destroy(); resolve(true) })
    s.once('timeout', () => { s.destroy(); resolve(false) })
    s.once('error', () => resolve(false))
    s.connect(port, '127.0.0.1')
  })
}

// -- 脚本入口 -----------------------------------------------------------------
const argv = process.argv.slice(2)
const argOf = (name) => {
  const i = argv.indexOf(name)
  return i >= 0 && i + 1 < argv.length ? argv[i + 1] : null
}
if (process.argv[1] && /[\\/]web\.js$/.test(process.argv[1])) {
  const port = Number(argOf('--port')) || DEFAULT_WEB_PORT
  const vault = argOf('--vault') || defaultVaultDir()
  startWebServer({ port, vaultRoot: path.resolve(vault) })
  // 常驻：不主动退出；Ctrl+C / 进程被杀即停
  process.on('SIGINT', () => process.exit(0))
  process.on('SIGTERM', () => process.exit(0))
}
