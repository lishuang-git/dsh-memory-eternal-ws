param(
  [string]$Profile = 'web',
  [switch]$KeepSettings
)
$ErrorActionPreference = 'Stop'
$enc = New-Object System.Text.UTF8Encoding $false
$dsh = if ($env:DSH_HOME) { $env:DSH_HOME } else { Join-Path $env:USERPROFILE '.dsh' }
$profileRoot = Join-Path $dsh "profiles\$Profile"
$pkgName = 'dsh-memory-eternal-ws'
$upstream = 'dsh-memory-eternal'
$dst = Join-Path $profileRoot "node_modules\$pkgName"

# 1) bundles 回退
$pjPath = Join-Path $profileRoot 'package.json'
Copy-Item $pjPath "$pjPath.bak-$(Get-Date -Format yyyyMMdd-HHmmss)" -Force
$pj = [System.IO.File]::ReadAllText($pjPath, [System.Text.Encoding]::UTF8)
if ($pj -match ('"' + [regex]::Escape($pkgName) + '",')) {
  $pj = $pj.Replace('"' + $pkgName + '",', '"' + $upstream + '",')
  [System.IO.File]::WriteAllText($pjPath, $pj, $enc)
  Write-Host "[1/2] bundles 已回退：$pkgName → $upstream"
}
else { Write-Host '[1/2] bundles 未引用新插件，跳过' }

# 2) 移除包体
if (Test-Path $dst) { Remove-Item $dst -Recurse -Force; Write-Host "[2/2] 已移除 $dst" }
else { Write-Host '[2/2] 包目录不存在，跳过' }

if (-not $KeepSettings) {
  Write-Host ''
  Write-Host '提示：settings.yaml 里的 memory-eternal-ws 段已保留（原版不读取它，无副作用）；'
  Write-Host '      如需清理请手动删除该段。'
}
Write-Host ''
Write-Host '卸载完成：请重启 DSH 生效。各项目的 .dsh\memory-vault\ 数据未被删除。'
