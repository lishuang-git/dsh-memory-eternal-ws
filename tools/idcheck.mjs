// 校验 client bundle 的注册 id 是否等于包名。
//
// 为什么需要：lib/client.js 由 build.mjs 生成，包装成
//   window.__ModuleLoader__.load({ id, factory })
// DSH 要求这里的 id 等于包的 name，否则前端整页报
//   `client-modules: bundle ... loaded without registering "<包名>" via __ModuleLoader__.load`
// （校验点：@deepseek-ai/dsh-client-modules/lib/client.js 的 `if (!this.factories.has(id)) throw`）。
//
// 用法：node tools/idcheck.mjs <包目录>\lib\client.js <包目录>\package.json
// 退出码：0 = 一致；1 = 不一致；2 = 参数缺失
import fs from 'node:fs'

const clientJs = process.argv[2]
const pkgJson = process.argv[3]
if (!clientJs || !pkgJson) {
  console.error('用法: node idcheck.mjs <lib/client.js> <package.json>')
  process.exit(2)
}

const registered = []
globalThis.window = { __ModuleLoader__: { load: (def) => registered.push(def && def.id) } }
try {
  ;(0, eval)(fs.readFileSync(clientJs, 'utf8'))
} catch (error) {
  console.error('[X] 执行 bundle 失败：' + (error && error.message))
  process.exit(1)
}

const pkgName = JSON.parse(fs.readFileSync(pkgJson, 'utf8')).name
if (registered.length !== 1 || registered[0] !== pkgName) {
  console.error('[X] 包名=' + pkgName + '  注册 id=' + JSON.stringify(registered))
  console.error('    请把 build.mjs 的 PACKAGE_ID 改成包名后重新执行：node build.mjs')
  process.exit(1)
}
console.log('[OK] client bundle 注册 id = ' + pkgName)
