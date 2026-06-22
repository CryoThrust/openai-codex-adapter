# ═══════════════════════════════════════════════════════════
# OpenAI-Codex Adapter — Windows 切换 Provider
# ═══════════════════════════════════════════════════════════
$ErrorActionPreference = "Stop"
$InstallDir = "$env:USERPROFILE\.openai-codex-adapter"
$TaskName = "OpenAI-Codex-Adapter"
$ConfigFile = "$InstallDir\config.env"

if (-not (Test-Path $ConfigFile)) { Write-Host "ERROR: 未安装" -ForegroundColor Red; exit 1 }

# 读取当前配置
$currentConfig = @{}
Get-Content $ConfigFile | Where-Object { $_ -notmatch "^\s*#" -and $_ -match "=" } | ForEach-Object {
    $parts = $_ -split "=", 2
    $currentConfig[$parts[0].Trim()] = $parts[1].Trim()
}

Write-Host ""
Write-Host "═══ 当前配置 ═══" -ForegroundColor Cyan
Write-Host "  上游: $($currentConfig['ADAPTER_UPSTREAM'])" -ForegroundColor Green
Write-Host "  模型: $($currentConfig['ADAPTER_MODEL'])" -ForegroundColor Green
Write-Host "  端口: $($currentConfig['ADAPTER_PORT'])" -ForegroundColor Green
Write-Host "  上下文: $($currentConfig['ADAPTER_CONTEXT_WINDOW']) tokens (压缩: $($currentConfig['ADAPTER_AUTO_COMPACT_LIMIT']))" -ForegroundColor Green
Write-Host ""

$Providers = [ordered]@{
    "1" = @{ Name = "DeepSeek";          Url = "https://api.deepseek.com/v1/chat/completions";           Model = "deepseek-chat";           ContextWindow = 128000 }
    "2" = @{ Name = "讯飞星辰";          Url = "https://maas-coding-api.cn-huabei-1.xf-yun.com/v2/chat/completions"; Model = "astron-code-latest"; ContextWindow = 200000 }
    "3" = @{ Name = "Ollama (本地)";      Url = "http://127.0.0.1:11434/v1/chat/completions";            Model = "qwen2.5-coder:7b";       ContextWindow = 128000 }
    "4" = @{ Name = "LM Studio (本地)";   Url = "http://127.0.0.1:1234/v1/chat/completions";            Model = "default";                 ContextWindow = 128000 }
    "5" = @{ Name = "SiliconFlow";        Url = "https://api.siliconflow.cn/v1/chat/completions";        Model = "deepseek-ai/DeepSeek-V3"; ContextWindow = 128000 }
    "6" = @{ Name = "OpenAI (官方)";      Url = "https://api.openai.com/v1/chat/completions";            Model = "gpt-4o";                  ContextWindow = 128000 }
    "7" = @{ Name = "自定义";             Url = "";                                                       Model = "";                        ContextWindow = 0 }
    "0" = @{ Name = "仅改 Key/模型/端口"; Url = "";                                                       Model = "";                        ContextWindow = 0 }
}

Write-Host "═══ 选择新 Provider ═══" -ForegroundColor Cyan
foreach ($key in $Providers.Keys) {
    Write-Host "  $key) $($Providers[$key].Name)"
}
Write-Host ""
$choice = Read-Host "请输入编号 [0-7]"
if (-not $Providers.ContainsKey($choice)) { Write-Host "ERROR: 无效选择" -ForegroundColor Red; exit 1 }

$newUrl = $currentConfig['ADAPTER_UPSTREAM']
$newModel = $currentConfig['ADAPTER_MODEL']
$newKey = $currentConfig['ADAPTER_API_KEY']
$newPort = $currentConfig['ADAPTER_PORT']

if ($choice -ne "0") {
    if ($choice -eq "7") {
        $newUrl = Read-Host "API 地址"
        if (-not $newUrl) { exit 1 }
    } else {
        $newUrl = $Providers[$choice].Url
    }
    $defaultModel = $Providers[$choice].Model
    if ($defaultModel) {
        $m = Read-Host "模型 [默认: $defaultModel]"
        $newModel = if ($m) { $m } else { $defaultModel }
    } else {
        $newModel = Read-Host "模型"
    }
    if ($choice -eq "3" -or $choice -eq "4") {
        $newKey = "local-no-key"
    } else {
        Write-Host "API Key (留空不变): " -NoNewline
        $k = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
            [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR((Read-Host -AsSecureString))
        )
        if ($k) { $newKey = $k }
    }
} else {
    $u = Read-Host "新 API 地址 (留空不变)"
    if ($u) { $newUrl = $u }
    $m = Read-Host "新模型 (留空不变)"
    if ($m) { $newModel = $m }
    Write-Host "新 API Key (留空不变): " -NoNewline
    $k = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR((Read-Host -AsSecureString))
    )
    if ($k) { $newKey = $k }
}

$p = Read-Host "端口 [当前: $newPort, 回车不变]"
if ($p) { $newPort = $p }

# ── 上下文窗口 ────────────────────────────────────
$currentContext = if ($currentConfig['ADAPTER_CONTEXT_WINDOW']) { [int]$currentConfig['ADAPTER_CONTEXT_WINDOW'] } else { 0 }
$currentCompact = if ($currentConfig['ADAPTER_AUTO_COMPACT_LIMIT']) { [int]$currentConfig['ADAPTER_AUTO_COMPACT_LIMIT'] } else { 0 }
$newContext = $currentContext
$newCompact = $currentCompact

if ($choice -ne "0") {
    $presetCtx = $Providers[$choice].ContextWindow
    if ($presetCtx -gt 0) {
        Write-Host "  模型上下文窗口: $presetCtx tokens" -ForegroundColor Cyan
        $ctxInput = Read-Host "  确认或自定义 [回车确认 / 输入数值]"
        if ($ctxInput) { $newContext = [int]$ctxInput } else { $newContext = $presetCtx }
    } else {
        $ctxInput = Read-Host "  上下文窗口 (当前: $currentContext, 0=不限)"
        if ($ctxInput) { $newContext = [int]$ctxInput }
    }
} else {
    $ctxInput = Read-Host "  上下文窗口 (当前: $currentContext, 回车不变)"
    if ($ctxInput) { $newContext = [int]$ctxInput }
}

if ($newContext -gt 0) {
    $defaultCompact = [math]::Floor($newContext * 0.8)
    $compactInput = Read-Host "  自动压缩阈值 [当前: $currentCompact, 默认80%=$defaultCompact]"
    if ($compactInput) { $newCompact = [int]$compactInput }
    elseif ($currentCompact -eq 0 -or $choice -ne "0") { $newCompact = $defaultCompact }
} else {
    $newCompact = 0
}

# 写配置
$envContent = @"
ADAPTER_HOST=127.0.0.1
ADAPTER_PORT=$newPort
ADAPTER_UPSTREAM=$newUrl
ADAPTER_MODEL=$newModel
ADAPTER_API_KEY=$newKey
ADAPTER_RETRY_MAX=$($currentConfig['ADAPTER_RETRY_MAX'])
ADAPTER_RETRY_DELAY=$($currentConfig['ADAPTER_RETRY_DELAY'])
ADAPTER_CONTEXT_WINDOW=$newContext
ADAPTER_AUTO_COMPACT_LIMIT=$newCompact
"@
Set-Content -Path $ConfigFile -Value $envContent -Encoding UTF8

# 更新计划任务环境变量并重启
$python = (Get-Command python -ErrorAction SilentlyContinue) ?? (Get-Command python3 -ErrorAction SilentlyContinue)
$action = New-ScheduledTaskAction -Execute $python.Source -Argument "$InstallDir\adapter.py"
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
$trigger = New-ScheduledTaskTrigger -AtLogOn
Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Description "OpenAI-Codex Adapter" -RunLevel Highest -Force | Out-Null
Start-ScheduledTask -TaskName $TaskName

Write-Host ""
Write-Host "✅ 已切换并重启" -ForegroundColor Green
Write-Host "  上游: $newUrl" -ForegroundColor Cyan
Write-Host "  模型: $newModel" -ForegroundColor Cyan
Write-Host "  端口: $newPort" -ForegroundColor Cyan
Write-Host "  上下文: $newContext tokens (压缩阈值: $newCompact)" -ForegroundColor Cyan
Write-Host ""
Write-Host "⚠️  请重启 Codex 生效" -ForegroundColor Yellow
