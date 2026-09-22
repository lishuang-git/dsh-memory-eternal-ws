<#
.SYNOPSIS
  验证 dsh-memory-eternal-ws 的「按工作区自动切库」是否生效。
.DESCRIPTION
  DSH 重启后运行本脚本：
    1) 查看宿主 API 当前解析出的记忆库（应指向当前项目的 .dsh\memory-vault）
    2) 用 workspace.json 里登记的每个工作区逐个模拟 ?cwd=，确认各自落到不同库
    3) 打印 profile bundles 与插件包状态
.EXAMPLE
  powershell -File tools\verify.ps1
.EXAMPLE
  powershell -File tools\verify.ps1 -Port 3080
#>
param(
  [int]$Port = 3080
)
$ErrorActionPreference = 'Continue'
$dsh = if ($env:DSH_HOME) { $env:DSH_HOME } else { Join-Path $env:USERPROFILE '.dsh' }

function Probe([string]$label, [string]$url) {
  try {
    $j = (Invoke-WebRequest $url -TimeoutSec 8 -UseBasicParsing).Content | ConvertFrom-Json
    Write-Host ("  {0,-26} vaultDir={1}" -f $label, $j.vaultDir)
    Write-Host ("  {0,-26} total={1}  byKind={2}" -f '', $j.total, (($j.byKind.PSObject.Properties | ForEach-Object { "$($_.Name):$($_.Value)" }) -join ' '))
    return $j
  }
  catch {
    Write-Host ("  {0,-26} ERR {1}" -f $label, $_.Exception.Message)
    return $null
  }
}

Write-Host '=== 1) 宿主 API（当前工作区）==='
$base = "http://127.0.0.1:$Port/memory-eternal/api"
$cur = Probe '当前工作区' "$base/overview"

Write-Host ''
Write-Host '=== 2) 逐个工作区模拟 ?cwd= ==='
$wsFile = Join-Path $dsh 'storages\workspace.json'
$seen = @{}
if (Test-Path $wsFile) {
  $tbl = (Get-Content $wsFile -Raw | ConvertFrom-Json).tables.workspaces
  foreach ($p in $tbl.PSObject.Properties) {
    $path = $p.Value.path
    if (-not $path) { continue }
    $enc = [uri]::EscapeDataString($path)
    $j = Probe ("cwd=" + $p.Value.title) "$base/overview?cwd=$enc"
    if ($j) {
      $expected = Join-Path $path '.dsh\memory-vault'
      $ok = ($j.vaultDir -replace '/', '\').TrimEnd('\') -ieq $expected.TrimEnd('\')
      Write-Host ("  {0,-26} 期望={1}  {2}" -f '', $expected, $(if ($ok) { '[OK]' } else { '[不一致]' }))
      if ($seen.ContainsKey($j.vaultDir)) { Write-Host ("  {0,-26} [警告] 与其它工作区指向同一库" -f '') }
      $seen[$j.vaultDir] = $true
    }
  }
}
else { Write-Host "  找不到 $wsFile" }

Write-Host ''
Write-Host '=== 3) 部署状态 ==='
$pj = Join-Path $dsh 'profiles\web\package.json'
if (Test-Path $pj) {
  $bundles = (Get-Content $pj -Raw | ConvertFrom-Json).dsh.profile.bundles
  Write-Host ("  bundles: " + ($bundles -join ', '))
  Write-Host ("  使用新插件: " + ($bundles -contains 'dsh-memory-eternal-ws'))
}
$pkg = Join-Path $dsh 'profiles\web\node_modules\dsh-memory-eternal-ws'
Write-Host ("  插件包存在: " + (Test-Path (Join-Path $pkg 'index.js')))
$sp = Join-Path $dsh 'settings.yaml'
if (Test-Path $sp) {
  $raw = [System.IO.File]::ReadAllText($sp, [System.Text.Encoding]::UTF8)
  Write-Host ("  settings 含 memory-eternal-ws 段: " + ($raw -match '(?m)^memory-eternal-ws:'))
  if ($raw -match '(?m)^  vaultMode:\s*(\S+)') { Write-Host ("  vaultMode = " + $Matches[1]) }
  if ($raw -match '(?m)^  vaultRelPath:\s*''?([^''\r\n]+)''?') { Write-Host ("  vaultRelPath = " + $Matches[1]) }
}

Write-Host ''
Write-Host '判定标准：'
Write-Host '  · 第 1 段的 vaultDir 应等于「当前项目根 \ .dsh\memory-vault」；'
Write-Host '  · 第 2 段每个工作区应显示 [OK]，且任意两个工作区的 vaultDir 不重复；'
Write-Host '  · 若第 1 段仍是 C:\Users\...\.dsh\memory-vault，说明插件未生效（确认已重启 DSH）。'
