# dsh-memory-eternal-ws —— 工作区版记忆核心

> ## 来源与许可
>
> 本项目是 [`EternalNight996/dsh-memory-eternal`](https://github.com/EternalNight996/dsh-memory-eternal) **v0.7.0** 的
> **fork（复刻改造）**，不是原作者发布的版本。上游以 **MIT** 许可发布，**版权归原作者所有**；
> 本 fork 同样以 MIT 发布，并保留上游 `LICENSE` 原文。请勿把本 fork 的问题反馈给上游仓库。
>
> **保留全部原有功能**（对话自动沉淀 / 自动召回 / 知识卡 / 知识图谱 / 审核中心 / 回收站 / 记忆配置页 /
> 独立 web / MCP / hooks / sweep），新增 **按 DSH 工作区自动切库**；改动清单见「六」。

## 一、与原版的行为差异

**一句话**：原版全局只有一个记忆库（靠设置项 `activeVault` 手动切）；本版按「当前会话所属工作区」自动选库，
每个项目一个独立库，切工作区即切库，且天然支持多工作区并行（互不串库）。

### 新增配置项

| 配置项 | 默认 | 说明 |
|---|---|---|
| `vaultMode` | `workspace` | `workspace`=每个项目用自己的库；`global`=全部共用一个库（等同原版行为） |
| `vaultRelPath` | `.dsh/memory-vault` | 项目库相对**工作区根**的路径 |
| `globalVaultDir` | `''` | 全局/跨项目共享库；空 = `<DSH_HOME>/memory-vault`（`vaultDir` 非空时优先 `vaultDir`） |
| `includeGlobalVault` | `true` | `memory_recall` 是否合并全局库结果（跨项目知识） |

原有配置项全部保留，语义不变。

### 库解析顺序

1. **手动覆盖**：`vaultProfiles` 里选中的 `activeVault`（兼容原版行为，调试用）
2. `vaultMode === 'global'` → 全局库
3. 否则 → **当前会话所属工作区根** + `vaultRelPath`
4. 解析不出工作区（如无会话上下文的定时任务）→ 全局库兜底

**工作区根怎么来的**：取 `agent.session.cwd`（或 `session.header.cwd`），
对 `ctx.workspaceRegistry.list()` 的工作区路径做**最长前缀匹配**；
注册表不可用时退化为 cwd 本身。

## 二、各链路如何拿到「当前工作区」

| 链路 | 取值方式 |
|---|---|
| `memory_recall` 工具 | `execute(args, exec)` → `exec.agent.session.header.cwd` |
| 自动沉淀（turn-stopping） | 事件回调里的 `agent` → 同上 |
| 宿主 HTTP API（`/memory-eternal/api/*`） | 请求 query 的 `?cwd=`（其次 `?vault=`），由 `deps.resolveVault(req, query)` 注入 |
| 前端面板 | **影子包裹 `globalThis.fetch`**：自动给所有 `/memory-eternal/api*` 请求补 `?cwd=`；取值优先级 ① URL 上的 `?cwd=`（iframe/独立页）② DSH 客户端 `sessions` store 的 `sessions.list.getSnapshot()` → `current` + `byId[id].cwd` |
| iframe（跨源） | 父页把 `currentCwd()` 拼进 iframe `src` 的 `?cwd=`，iframe 内复用同一段取值逻辑 |
| daily 简报 / 回收站清理 | 遍历 `vaultRoots()`（全局库 + 每个工作区项目库 + 手动登记库） |

> 关键设计：**每次调用实时解析**，不依赖任何「当前工作区」全局状态或切换事件
> —— DSH 本身没有全局的「当前工作区」，切换工作区只表现为当前会话变化。

## 三、安装

```powershell
# 1) 构建（需要 node >= 22）
cd <包目录>
npm i
node build.mjs          # 产出 lib/client.js + web/app.js

# 2) 装进 profile（复制包 + 改 bundles + 写配置段），脚本见 tools\install.ps1
powershell -File tools\install.ps1

# 3) 重启 DSH（bundle 列表变更必须重启才生效）
```

重启后：

- 侧边栏底部「记忆」按钮 / 设置 → 记忆：界面不变，但数据来自**当前项目**的库；
- 在项目 A 里的对话只写 A 的库，切到项目 B 就是 B 的库；
- 已有的卡片若原在集中库，会被 `tools\install.ps1` 迁移到当前项目库。

### 一键验证（重启后运行）

```powershell
powershell -File tools\verify.ps1
```

判定标准：

- 第 1 段的 `vaultDir` 应等于「当前项目根 \ `.dsh\memory-vault`」；
- 第 2 段用 `storages\workspace.json` 里登记的每个工作区逐个模拟 `?cwd=`，应各自显示 `[OK]`、且**任意两个工作区的 vaultDir 不重复**；
- 若第 1 段仍指向 `C:\Users\...\.dsh\memory-vault`，或第 2 段全部指向同一个库，说明插件未生效（确认已重启 DSH）。

## 四、卸载 / 回退到原版

```powershell
powershell -File tools\uninstall.ps1     # 改回 bundles、移除包目录
# 然后重启 DSH
```

`settings.yaml` 里的 `memory-eternal-ws:` 段可以保留（原版不读它）。

## 五、已知限制

1. **首次生效必须重启 DSH**：`dsh.profile.bundles` 变更不参与 HMR。
2. **独立 web（7999）同时只服务一个库**：原版靠 `--vault`/`MEMORY_VAULT_DIR` 绑定单库；
   本版让宿主同源 API（面板主链路）按请求切库，独立 web 主要用于浏览器直连浏览。
   已修掉原版「探活不校验库 → 旧实例永久占位」的 bug（`lib/web.js` 的 `probeWebServer` 增加 `expectVault`）。
3. **一个工作区一个库**：工作区内的子目录会话会归到工作区根（符合 DSH 的工作区语义，
   即「成员资格 = 会话 cwd 等于工作区路径」）。
4. **`vaultProfiles` / `activeVault` 仍会覆盖自动选库**：留着是为了兼容与调试；想让自动选库生效，把它俩清空。
6. **MCP / hooks / CLI（`dsh-memory` 命令、`lib/capture-run.js`）不按工作区切库**：它们是给 Claude Code / Codex / Cursor
   等**外部 agent** 用的独立入口，只能看到 `MEMORY_VAULT_DIR` 或全局默认库。DSH 内部的三条链路（召回 / 沉淀 / 面板）
   已全部按工作区切库。若要让外部 agent 也分库，在调用前设置
   `MEMORY_VAULT_DIR=<项目根>\.dsh\memory-vault` 即可。
7. **审核中心 / 知识图谱 / 回收站 / 配置页等 UI 功能未改动**：只改了「库目录从哪来」，页面与 API 形状不变
   （`npm test` 覆盖 overview / cards / search / graph / stats / optimize / audit 的返回形状）。
8. **上游已转向新项目**（`memory-eternal`，SQLite 存储）。本仓库基于 0.7.0 的 Markdown 版，
   以获得「库是可读、可 git 的 .md」这一特性；新版的修复可按需手动移植（本次已移植一条，见下）。

### 关于 git 与备份

- `<项目>\.dsh\memory-vault\` 是普通目录，**会被 git 跟踪**（本项目 `.gitignore` 只忽略了 `/.dsh-runtime-log/`）。
  想让记忆随项目提交/备份就保持现状；不想入库就在项目 `.gitignore` 里加一行 `.dsh/`。
- 迁移前的集中库 `<DSH_HOME>\memory-vault-projects\mwrs.ui` **保留未删**，作为回退备份，
  确认新插件工作正常后可自行删除。
- 全局库仍是 `<DSH_HOME>\memory-vault`（原先指向项目库的 junction 已撤销）。
## 六、本次相对上游 0.7.0 的改动清单

| 文件 | 改动 |
|---|---|
| `index.js` | ① `Config` 新增 4 个工作区字段；② 新增 `globalVaultDir/manualVault/workspaceRootFor/vaultFor/agentCwd`，重写 `vaultDir/vaultRoots`；③ `runCapture` 用 `vaultFor(agentCwd(agent))`；④ `memory_recall` 改为 `execute(args, exec)` 并按调用方工作区检索（可合并全局库）；⑤ 系统提示文案不再写死单一库路径；⑥ daily/purge 遍历所有库；⑦ 注入 `resolveVault` 给 API；⑧ **移植新版修复**：会话事件三级自适应 `ownEvents() → snapshotEvents() → events`；⑨ 插件名与 settings 命名空间改为 `memory-eternal-ws` |
| `lib/api.js` | `vaultRoot` 解析下移到 `query` 之后，改为 `deps.resolveVault(req, query) || vaultDir()` |
| `lib/web.js` | ① `probeWebServer` 增加 `expectVault` 校验、`ensureWebServer` 传入期望库（避免旧实例永久占位）；② `startWebServer` 的 `createApi` **注入 `resolveVault`**，使独立 web / iframe 面板也能按 `?cwd=` 切库（原版缺这个 resolver，是「切工作区后面板仍显示旧库」的根因之一） |
| `src/client/index.tsx` | ① `inject` 增加 `'sessions'`；② 新增 `currentCwd()` + `installCwdFetch()`（影子包裹 fetch，幂等）；③ `apply()` 保存 ctx；④ iframe `src` 透传 `?cwd=` |
| `package.json` | name → `dsh-memory-eternal-ws`，version → `0.8.0-ws.1` |
| `cordis.patch.yml` | `id`/`name` 改为 `memory-eternal-ws` / `dsh-memory-eternal-ws` |

> 构建产物：`lib/client.js`（121711 → 122606 字符）、`web/app.js`（255KB）。
> 回归：`npm test` 全绿（21 项）。

## 七、给上游提 PR 的建议

改动集中在 6 个文件、约 250 行，且**默认值即「按项目分库」**。若你希望回馈上游，
可把 `vaultMode` 默认改成 `global` 再提 PR —— 那样对原用户零行为变化，同时多出可选的按工作区模式。

## 八、验证记录

### 已实测（无需重启 DSH 即可验证的部分）

| 项 | 方法 | 结果 |
|---|---|---|
| 产物语法 | `node --check` × 8 个产物 | 全部 OK |
| 回归测试 | `npm test` | 21 项全绿 |
| 构建 | `node build.mjs` | `lib/client.js` 122606 字符 / `web/app.js` 255.7KB |
| 前端注入 | 检查 `lib/client.js` | `inject` 含 `sessions`；`currentCwd()`、`__memoryEternalWsFetch` 已打入 |
| **按 cwd 切库（端到端）** | 起 `node lib/web.js --port 8011 --vault <全局库>`，用不同 `?cwd=` 请求 `/memory-eternal/api/overview` | 无 cwd → 全局库（total 2）；`cwd=<mwrs.ui>` → `E:\...\mwrs.ui\.dsh\memory-vault`（total 17）；`cwd=<新目录>` → `<该目录>\.dsh\memory-vault`（自动建库，total 0） |

### 真实环境验证（重启 DSH 后实测通过）

| 项 | 方法 | 结果 |
|---|---|---|
| 切库（宿主 API） | `tools/verify.ps1` | 5 个工作区**全部 `[OK]`**：`dshWorkSpace` / `mwrs.ui`(17 张) / `mnis` / `pda` / `llstack` 各指向自己的 `.dsh\memory-vault`，互不重复 |
| 切库（独立 web 7999，即面板 iframe 链路） | 对 7999 请求 `/memory-eternal/api/overview` | 不带 cwd → 全局库(2)；`?cwd=<mwrs.ui>` → 项目库(**17**) |
| 召回 | 让 Agent 调 `memory_recall` | 命中 `02-Projects/mwrs.ui-项目总览.md`、`03-Knowledge/mwrs.ui-工程规范与目录约定.md` 等项目库卡片 |
| **面板 UI** | DSH 侧边栏底部「记忆」 | 显示 **17 张**（3 项目 / 5 知识 / 3 内容 / 2 工具 / 1 教训 / 3 系统简报），审核中心 / 知识图谱 / 回收站 / 配置页正常渲染 |
| 自动沉淀 | 项目库 `00-System/daily-*.md` | 每日回顾正常写入**当前项目**的库 |

> 无会话上下文的裸请求（如直接访问 7999 根路径）会退回**全局库** —— 这是设计上的兜底，不是故障。
> 首次重启曾因 `build.mjs` 的 `PACKAGE_ID` 未随包名同步导致前端整页白屏；已修复并把校验内建进 `tools/install.ps1`（见「九、踩过的坑」）。

## 九、踩过的坑（排障备忘）

### 1. 客户端 bundle 注册 id 必须等于包名（否则整页白屏）

`lib/client.js` 由 `build.mjs` 生成，包装成 `window.__ModuleLoader__.load({ id, factory })`，
`id` 取自 `build.mjs` 顶部的 `PACKAGE_ID`。**DSH 要求该 id 等于包的 `name`**，否则前端整页报：

```
Failed to load plugins
failed to import loader entry ...: client-modules: bundle ... loaded without registering
"dsh-memory-eternal-ws" via __ModuleLoader__.load
```

校验点在 `@deepseek-ai/dsh-client-modules/lib/client.js`：`if (!this.factories.has(id)) throw ...`，
其中 `id` 来自 bundle 图里的包名。

> 本项目踩过：改名时改了 `package.json.name` 与 `cordis.patch.yml`，却漏改 `build.mjs` 的 `PACKAGE_ID`，
> 导致 bundle 仍注册旧 id，重启后整页加载失败。**改名必须同步三处**：
> `package.json.name`、`build.mjs` 的 `PACKAGE_ID`、`cordis.patch.yml` 的 `id` / `name`。

`tools/install.ps1` 已内建该校验（不一致直接中止，不会让你重启后才发现）。手动自查：

```powershell
node <包目录>\tools\idcheck.mjs "<包目录>\lib\client.js" "<包目录>\package.json"
```

### 2. 前端取「当前会话目录」的兼容写法

`ctx.get('sessions').list` 在不同 DSH 版本上可能是 `ObservableSnapshot` / `SnapshotStore` / 直接值，
`src/client/index.tsx` 的 `readSnapshot()` 会依次尝试 `getSnapshot()`、`get()`、`.snapshot`、值本身，
再从 `SessionListState{ byId, current }` 取 `SessionSummary.cwd`（兼容 `header.cwd`）。
拿不到时回退到 URL 上的 `?cwd=`，再拿不到就让后端用默认库 —— 不报错，只是退化为单库。

## 十、分发给其他人

### 别人怎么装

方式 A（走 npm，最省事）：

```bash
dsh plugin --profile web add dsh-memory-eternal-ws
# 然后重启 DSH
```

方式 B（拿到 Git 仓库或 zip 后本地安装，无需任何参数）：

```powershell
powershell -File <包目录>\tools\install.ps1
# 然后重启 DSH
```

`tools\install.ps1` 是**零配置**的：默认以脚本所在目录的父目录为包根，profile 从 `$DSH_HOME` 推导；
复制完包体后会调用 `tools/idcheck.mjs` 校验「bundle 注册 id == 包名」，不一致立即中止（避免重启后才发现白屏）。

卸载：`powershell -File <包目录>\tools\uninstall.ps1`（把 profile 的 bundles 改回上游插件名并移除本包），再重启。

### 发布到 npm 前的检查单

1. `package.json` 里把 `YOUR_GITHUB_USER` / `YOUR_NAME` 换成你自己的（`repository`、`homepage`、`author` 三处）；
2. 若改用 scope（如 `@you/dsh-memory-eternal-ws`），**必须同步 `build.mjs` 的 `PACKAGE_ID`**，
   两者不一致会导致前端整页 `Failed to load plugins`（见「九、踩过的坑」）；
3. `npm whoami` 确认已登录；
4. `npm pack --dry-run` 确认包内容包含 `index.js` / `lib` / `web` / `tools` / `cordis.patch.yml`；
5. `npm publish`（首次发 public 包用 `npm publish --access public`）。

### 跨环境风险（未验证部分）

- 只在 Windows + 单一 DSH 版本上验证过，未在他人环境实测；
- 前端取「当前会话目录」依赖 `ctx.get('sessions')` 的结构，DSH 版本差异会导致**退化为单库**（不报错）；
- 上游已转向 `memory-eternal`（SQLite 版），本 fork 基于 0.7.0（Markdown），上游后续修复需手动移植。