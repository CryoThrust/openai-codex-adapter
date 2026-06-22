# ═══════════════════════════════════════════════════════════════════
# OpenAI-Codex Adapter — Windows 一键安装
# 用法: powershell -NoProfile -ExecutionPolicy Bypass -Command "irm https://gitee.com/CryoThrust/openai-codex-adapter/raw/main/install.ps1 | iex"
# ═══════════════════════════════════════════════════════════════════
$ErrorActionPreference = "Stop"

$InstallDir = "$env:USERPROFILE\.openai-codex-adapter"
$TaskName = "OpenAI-Codex-Adapter"
$CodexDir = "$env:USERPROFILE\.codex"

# ── 已安装检测 ────────────────────────────────────────
if (Test-Path "$InstallDir\config.env") {
    $currentConfig = @{}
    Get-Content "$InstallDir\config.env" | Where-Object { $_ -notmatch "^\s*#" -and $_ -match "=" } | ForEach-Object {
        $parts = $_ -split "=", 2
        $currentConfig[$parts[0].Trim()] = $parts[1].Trim()
    }

    $healthStatus = "stopped"
    try {
        $r = Invoke-WebRequest -Uri "http://127.0.0.1:$($currentConfig['ADAPTER_PORT'])/health" -UseBasicParsing -TimeoutSec 2 -ErrorAction Stop
        if ($r.Content -match "ok") { $healthStatus = "running" }
    } catch { }

    Write-Host ""
    Write-Host "═══ 检测到已安装 ═══" -ForegroundColor Yellow
    Write-Host "  上游: $($currentConfig['ADAPTER_UPSTREAM'])" -ForegroundColor Cyan
    Write-Host "  模型: $($currentConfig['ADAPTER_MODEL'])" -ForegroundColor Cyan
    Write-Host "  端口: $($currentConfig['ADAPTER_PORT'])" -ForegroundColor Cyan
    Write-Host "  状态: $healthStatus" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  1) 重新配置 (切换 Provider / 修改 API Key)" -ForegroundColor White
    Write-Host "  2) 卸载" -ForegroundColor White
    Write-Host "  3) 取消退出" -ForegroundColor White
    Write-Host ""
    $reinstallChoice = Read-Host "请选择 [1-3]"

    switch ($reinstallChoice) {
        "1" {
            Write-Host "[INFO] 重新配置..." -ForegroundColor Cyan
            Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
        }
        "2" {
            & powershell -File "$InstallDir\uninstall.ps1"
            exit 0
        }
        default {
            Write-Host "已取消"
            exit 0
        }
    }
}

# ── 预设 Provider ─────────────────────────────────────
$Providers = [ordered]@{
    "1" = @{ Name = "DeepSeek";          Url = "https://api.deepseek.com/v1/chat/completions";           Model = "deepseek-chat" }
    "2" = @{ Name = "讯飞星辰 (Xfyun)";  Url = "https://maas-coding-api.cn-huabei-1.xf-yun.com/v2/chat/completions"; Model = "astron-code-latest" }
    "3" = @{ Name = "Ollama (本地)";      Url = "http://127.0.0.1:11434/v1/chat/completions";            Model = "qwen2.5-coder:7b" }
    "4" = @{ Name = "LM Studio (本地)";   Url = "http://127.0.0.1:1234/v1/chat/completions";            Model = "default" }
    "5" = @{ Name = "SiliconFlow";        Url = "https://api.siliconflow.cn/v1/chat/completions";        Model = "deepseek-ai/DeepSeek-V3" }
    "6" = @{ Name = "OpenAI (官方)";      Url = "https://api.openai.com/v1/chat/completions";            Model = "gpt-4o" }
    "7" = @{ Name = "自定义 (Custom)";    Url = "";                                                       Model = "" }
}

# ── 检查环境 ──────────────────────────────────────────
$python = Get-Command python -ErrorAction SilentlyContinue
if (-not $python) { $python = Get-Command python3 -ErrorAction SilentlyContinue }
if (-not $python) { Write-Host "ERROR: Python not found. Install from https://python.org" -ForegroundColor Red; exit 1 }
Write-Host "[OK] Python: $($python.Source)" -ForegroundColor Green

# ── 选择 Provider ─────────────────────────────────────
Write-Host ""
Write-Host "═══════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  OpenAI-Codex Adapter 安装向导" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""
Write-Host "请选择 API Provider:"
foreach ($key in $Providers.Keys) {
    Write-Host "  $key) $($Providers[$key].Name)" -ForegroundColor White
}
Write-Host ""
$choice = Read-Host "请输入编号 [1-7]"
if (-not $Providers.ContainsKey($choice)) { Write-Host "ERROR: 无效选择" -ForegroundColor Red; exit 1 }

$selected = $Providers[$choice]
$upstream = $selected.Url
$defaultModel = $selected.Model
Write-Host "[OK] 已选择: $($selected.Name)" -ForegroundColor Green

# ── 自定义 URL ────────────────────────────────────────
if ($choice -eq "7") {
    Write-Host ""
    $upstream = Read-Host "API 地址 (如 https://api.example.com/v1/chat/completions)"
    if (-not $upstream) { Write-Host "ERROR: 不能为空" -ForegroundColor Red; exit 1 }
}

# ── Model ─────────────────────────────────────────────
Write-Host ""
if ($defaultModel) {
    $model = Read-Host "模型名称 [默认: $defaultModel]"
    if (-not $model) { $model = $defaultModel }
} else {
    $model = Read-Host "模型名称"
    if (-not $model) { Write-Host "ERROR: 不能为空" -ForegroundColor Red; exit 1 }
}

# ── API Key ───────────────────────────────────────────
$needKey = $true
if ($choice -eq "3" -or $choice -eq "4") {
    $needKey = $false
    $apiKey = "local-no-key"
}
if ($needKey) {
    Write-Host ""
    Write-Host "API Key (输入不回显): " -NoNewline
    $apiKey = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR((Read-Host -AsSecureString))
    )
    if (-not $apiKey) { Write-Host "ERROR: 不能为空" -ForegroundColor Red; exit 1 }
}

# ── 端口 ──────────────────────────────────────────────
Write-Host ""
$port = Read-Host "端口 [默认: 18666]"
if (-not $port) { $port = "18666" }

# ── 安装文件 ──────────────────────────────────────────
Write-Host ""
Write-Host "[INFO] 安装到 $InstallDir ..." -ForegroundColor Cyan
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null

# 下载 adapter.py
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
if (Test-Path "$scriptDir\adapter.py") {
    Copy-Item "$scriptDir\adapter.py" "$InstallDir\adapter.py"
} else {
    $urls = @(
        "https://gitee.com/CryoThrust/openai-codex-adapter/raw/main/adapter.py",
        "https://raw.githubusercontent.com/CryoThrust/openai-codex-adapter/main/adapter.py"
    )
    $downloaded = $false
    foreach ($url in $urls) {
        try {
            Invoke-WebRequest -Uri $url -OutFile "$InstallDir\adapter.py" -UseBasicParsing
            $downloaded = $true
            break
        } catch { continue }
    }
    if (-not $downloaded) { Write-Host "ERROR: 下载 adapter.py 失败" -ForegroundColor Red; exit 1 }
}
Write-Host "[OK] 适配器已安装" -ForegroundColor Green

# 写配置
$envContent = @"
ADAPTER_HOST=127.0.0.1
ADAPTER_PORT=$port
ADAPTER_UPSTREAM=$upstream
ADAPTER_MODEL=$model
ADAPTER_API_KEY=$apiKey
ADAPTER_RETRY_MAX=5
ADAPTER_RETRY_DELAY=2.0
"@
Set-Content -Path "$InstallDir\config.env" -Value $envContent -Encoding UTF8

# 写启动脚本
$startScript = @"
@echo off
setlocal
for /f "usebackq tokens=1,* delims==" %%a in (`type "%~dp0config.env" ^| findstr /v "^#"`) do set "%%a=%%b"
start /b "" python "%~dp0adapter.py"
"@
Set-Content -Path "$InstallDir\start.bat" -Value $startScript -Encoding ASCII

# 写停止脚本
$stopScript = @"
@echo off
taskkill /f /fi "WINDOWTITLE eq OpenAI-Codex-Adapter" 2>nul
for /f "tokens=2" %%p in ('tasklist /fi "imagename eq python.exe" /fi "services eq " /fo list ^| findstr /i "PID" 2^>nul') do (
    wmic process where "processid=%%p and commandline like '%%adapter.py%%'" call terminate >nul 2>&1
)
echo Adapter stopped.
"@
Set-Content -Path "$InstallDir\stop.bat" -Value $stopScript -Encoding ASCII

Write-Host "[OK] 配置已写入" -ForegroundColor Green

# ── Windows 计划任务 (开机自启) ────────────────────────
$action = New-ScheduledTaskAction -Execute $python.Source -Argument "$InstallDir\adapter.py"
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
$trigger = New-ScheduledTaskTrigger -AtLogOn

$envVars = @{
    ADAPTER_HOST     = "127.0.0.1"
    ADAPTER_PORT     = $port
    ADAPTER_UPSTREAM = $upstream
    ADAPTER_MODEL    = $model
    ADAPTER_API_KEY  = $apiKey
    ADAPTER_RETRY_MAX  = "5"
    ADAPTER_RETRY_DELAY = "2.0"
}

Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Description "OpenAI-Codex Adapter" -RunLevel Highest -Force | Out-Null
Start-ScheduledTask -TaskName $TaskName

Write-Host "[OK] 开机自启已配置 (计划任务: $TaskName)" -ForegroundColor Green

# ── 自动配置 Codex ──────────────────────────────────────
$codex_configured = $false
Write-Host ""
$codex_choice = Read-Host "是否自动配置 Codex config.toml？[Y/n]"
if ($codex_choice -ne "n" -and $codex_choice -ne "N") {
    Write-Host "[INFO] 配置 Codex ..." -ForegroundColor Cyan
    $configPath = "$CodexDir\config.toml"
    $authPath = "$CodexDir\auth.json"
    New-Item -ItemType Directory -Force -Path $CodexDir | Out-Null

    if (Test-Path $configPath) {
        Copy-Item $configPath "$configPath.bak" -Force
        $existing = Get-Content $configPath -Raw -ErrorAction SilentlyContinue
        if ($existing) {
            $existing = $existing -replace "model_provider\s*=.*", "model_provider = `"custom`""
            $existing = $existing -replace "^model\s*=.*", "model = `"$model`""
            if ($existing -notmatch "\[model_providers\.custom\]") {
                if ($existing -match "\[model_providers\]") {
                    $existing = $existing -replace "\[model_providers\]", "[model_providers]`n[model_providers.custom]`nname = `"custom`"`nwire_api = `"responses`"`nrequires_openai_auth = true`nbase_url = `"http://127.0.0.1:$port/v1`""
                } else {
                    $existing += "`n`n[model_providers]`n[model_providers.custom]`nname = `"custom`"`nwire_api = `"responses`"`nrequires_openai_auth = true`nbase_url = `"http://127.0.0.1:$port/v1`""
                }
            } else {
                $existing = $existing -replace "base_url\s*=.*", "base_url = `"http://127.0.0.1:$port/v1`""
                $existing = $existing -replace "wire_api\s*=.*", "wire_api = `"responses`""
            }
            if ($existing -match "ANTHROPIC_AUTH_TOKEN") {
                $existing = $existing -replace "ANTHROPIC_AUTH_TOKEN\s*=.*", "ANTHROPIC_AUTH_TOKEN = `"$apiKey`""
            } elseif ($existing -match "\[shell_environment_policy\.set\]") {
                $existing = $existing -replace "\[shell_environment_policy\.set\]", "[shell_environment_policy.set]`nANTHROPIC_AUTH_TOKEN = `"$apiKey`""
            }
            Set-Content -Path $configPath -Value $existing -Encoding UTF8
        }
    } else {
        $freshConfig = @"
model_provider = "custom"
model = "$model"

[model_providers]
[model_providers.custom]
name = "custom"
wire_api = "responses"
requires_openai_auth = true
base_url = "http://127.0.0.1:$port/v1"

[shell_environment_policy]
inherit = "core"

[shell_environment_policy.set]
ANTHROPIC_AUTH_TOKEN = "$apiKey"
"@
        Set-Content -Path $configPath -Value $freshConfig -Encoding UTF8
    }
    @{ OPENAI_API_KEY = $apiKey } | ConvertTo-Json | Set-Content -Path $authPath -Encoding UTF8
    $codex_configured = $true
    Write-Host "[OK] Codex 已配置" -ForegroundColor Green
}

# ── 等待服务就绪 ──────────────────────────────────────
Write-Host "[INFO] 等待服务就绪..." -ForegroundColor Cyan
for ($i = 0; $i -lt 15; $i++) {
    try {
        $r = Invoke-WebRequest -Uri "http://127.0.0.1:$port/health" -UseBasicParsing -TimeoutSec 2 -ErrorAction Stop
        if ($r.Content -match "ok") { break }
    } catch { }
    Start-Sleep -Seconds 1
}

# ── 完成 ──────────────────────────────────────────────
Write-Host ""
Write-Host "════════════════════════════════════════════════" -ForegroundColor Green
Write-Host "  ✅ 安装完成！" -ForegroundColor Green
Write-Host "════════════════════════════════════════════════" -ForegroundColor Green
Write-Host ""
Write-Host "  Provider:  $($selected.Name)" -ForegroundColor Cyan
Write-Host "  上游地址:  $upstream" -ForegroundColor Cyan
Write-Host "  模型:      $model" -ForegroundColor Cyan
Write-Host "  适配器:    http://127.0.0.1:$port" -ForegroundColor Cyan
Write-Host "  健康检查:  curl http://127.0.0.1:$port/health" -ForegroundColor Cyan
Write-Host ""
if ($codex_configured) {
    Write-Host "  Codex config.toml 已自动配置" -ForegroundColor Green
} else {
    Write-Host "  Codex config.toml 未配置，请手动编辑 $CodexDir\config.toml" -ForegroundColor Yellow
    Write-Host "    model_provider = `"custom`"" -ForegroundColor Green
    Write-Host "    model = `"$model`"" -ForegroundColor Green
    Write-Host "    [model_providers.custom]" -ForegroundColor Green
    Write-Host "    wire_api = `"responses`"" -ForegroundColor Green
    Write-Host "    requires_openai_auth = true" -ForegroundColor Green
    Write-Host "    base_url = `"http://127.0.0.1:$port/v1`"" -ForegroundColor Green
}
Write-Host ""
Write-Host "  管理命令:" -ForegroundColor White
Write-Host "    启动:  $InstallDir\start.bat" -ForegroundColor Cyan
Write-Host "    停止:  $InstallDir\stop.bat" -ForegroundColor Cyan
Write-Host "    卸载:  powershell -File $InstallDir\uninstall.ps1" -ForegroundColor Cyan
Write-Host "    切换:  powershell -File $InstallDir\switch.ps1" -ForegroundColor Cyan
Write-Host ""
