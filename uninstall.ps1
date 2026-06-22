# ═══════════════════════════════════════════════════════════
# OpenAI-Codex Adapter — Windows 卸载
# ═══════════════════════════════════════════════════════════
$ErrorActionPreference = "Stop"
$InstallDir = "$env:USERPROFILE\.openai-codex-adapter"
$TaskName = "OpenAI-Codex-Adapter"

$confirm = Read-Host "确定要卸载？[y/N]"
if ($confirm -ne "y" -and $confirm -ne "Y") { Write-Host "已取消"; exit 0 }

# 停止计划任务
Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue

# 停止进程
Get-Process python -ErrorAction SilentlyContinue | Where-Object {
    $_.Path -like "*adapter*"
} | Stop-Process -Force -ErrorAction SilentlyContinue

# 删除安装目录
if (Test-Path $InstallDir) { Remove-Item -Recurse -Force $InstallDir }

Write-Host "✅ 卸载完成" -ForegroundColor Green
