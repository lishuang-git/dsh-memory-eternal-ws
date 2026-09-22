param(
  [string]$Source = (Split-Path -Parent $PSScriptRoot),
  [string]$Profile = 'web',
  [switch]$SkipBuild
)
$ErrorActionPreference = 'Stop'
$enc = New-Object System.Text.UTF8Encoding $false
$dsh = if ($env:DSH_HOME) { $env:DSH_HOME } else { Join-Path $env:USERPROFILE '.dsh' }
$profileRoot = Join-Path $dsh "profiles\$Profile"
if (-not (Test-Path $profileRoot)) { throw "profile 不存在：$profileRoot" }

$pkgName = 'dsh-memory-eternal-ws'
$upstream = 'dsh-memory-eternal'
$dst = Join-Path $profileRoot "node_modules\$pkgName"

# 1) 构建
if (-not $SkipBuild) {
  Push-Location $Source
  try {
    if (-not (Test-Path (Join-Path $Source 'node_modules'))) { npm i --no-audit --no-fund }
    node build.mjs
  }
  finally { Pop-Location }
}

# 2) 复制包体
New-Item -ItemType Directory -Path $dst -Force | Out-Null
foreach ($i in @('index.js', 'package.json', 'cordis.patch.yml', 'README.md', 'README-ws.md', 'LICENSE', 'lib', 'web', 'hooks', 'bin', 'skills', '.mcp.json', '.claude-plugin', '.codex-plugin', '.cursor-plugin')) {
  $p = Join-Path $Source $i
  if (Test-Path $p) { Copy-Item $p (Join-Path $dst $i) -Recurse -Force }
}
Write-Host "[1/3] 插件包已复制 → $dst"

# 1.5) 硬校验：client bundle 的注册 id 必须等于包名，否则 DSH 前端会报
#      `bundle ... loaded without registering "<包名>" via __ModuleLoader__.load` 并整页白屏。
#      根因通常是改了 package.json 的 name 却漏改 build.mjs 的 PACKAGE_ID。
& node (Join-Path $PSScriptRoot 'idcheck.mjs') (Join-Path $dst 'lib\client.js') (Join-Path $dst 'package.json')
if ($LASTEXITCODE -ne 0) { throw 'client bundle 注册 id 与包名不一致，已中止安装（bundles 未改动）' }

# 3) bundles 切换
$pjPath = Join-Path $profileRoot 'package.json'
Copy-Item $pjPath "$pjPath.bak-$(Get-Date -Format yyyyMMdd-HHmmss)" -Force
$pj = [System.IO.File]::ReadAllText($pjPath, [System.Text.Encoding]::UTF8)
if ($pj -match ('"' + [regex]::Escape($pkgName) + '",')) {
  Write-Host '[2/3] bundles 已是新插件，跳过'
}
else {
  $pj = $pj.Replace('"' + $upstream + '",', '"' + $pkgName + '",')
  [System.IO.File]::WriteAllText($pjPath, $pj, $enc)
  Write-Host "[2/3] bundles 已切换：$upstream → $pkgName"
}

# 4) settings.yaml 配置段（幂等）
$sp = Join-Path $dsh 'settings.yaml'
$raw = [System.IO.File]::ReadAllText($sp, [System.Text.Encoding]::UTF8)
if ($raw -match '(?m)^memory-eternal-ws:') {
  Write-Host '[3/3] settings.yaml 已有 memory-eternal-ws 段，跳过'
}
else {
  Copy-Item $sp "$sp.bak-$(Get-Date -Format yyyyMMdd-HHmmss)" -Force
  $seg = @'
memory-eternal-ws:
  autoCapture: true
  autoRecall: true
  recallLimit: 5
  recallSummaryLen: 130
  recallIncludeBody: false
  captureMinChars: 200
  captureCooldownMs: 300000
  dedupThreshold: 0.62
  maxCardsPerDay: 60
  distillEnabled: true
  dedupByLLM: true
  captureMaxTokens: 900
  recallMinScore: 2
  autoWeb: true
  autoWebMode: init
  webPort: 7999
  webCheckIntervalMs: 5000
  webMaxRestart: 10
  watchdogAutoSpawn: false
  autoMcpSetup: false
  auditMode: all
  auditExemptAgents: []
  auditExemptKinds: []
  recycleRetentionDays: 30
  vaultMode: workspace
  vaultRelPath: '.dsh/memory-vault'
  globalVaultDir: ''
  includeGlobalVault: true
  vaultProfiles: []
  activeVault: ''
'@
  [System.IO.File]::WriteAllText($sp, $raw.TrimEnd() + "`n" + $seg.TrimEnd() + "`n", $enc)
  Write-Host '[3/3] settings.yaml 已追加 memory-eternal-ws 段'
}

Write-Host ''
Write-Host '安装完成：请重启 DSH 生效（dsh.profile.bundles 变更不参与 HMR）。'
Write-Host '重启后：每个工作区各自使用 <工作区根>\.dsh\memory-vault\ 作为记忆库。'
