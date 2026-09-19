# OpenRouter 连通性测试（独立于 Godot，用来快速定位问题在哪一层）
#
# 为什么要独立一个脚本：出问题时可能是"代理没通"、"DNS 没解析"、"key 无效"、
# "模型名不对"四件事之一，用 Godot 测只能得到一个"失败"。这个脚本分层测，
# 每一步单独报告，能直接告诉你是哪一层断了。
#
# 用法（先确保 Clash Verge 已开着，且填好了 key）：
#   pwsh -File .\test-openrouter.ps1
#   pwsh -File .\test-openrouter.ps1 -Model "nvidia/nemotron-3-ultra-550b-a55b:free"
#   pwsh -File .\test-openrouter.ps1 -NoProxy          # 直连测（对比用）
param(
    [string]$Model = "nvidia/nemotron-3-ultra-550b-a55b:free",
    [string]$Proxy = "http://127.0.0.1:7897",
    [switch]$NoProxy,
    [int]$TimeoutSec = 40
)

$ErrorActionPreference = "Continue"
$ProjRoot = Split-Path -Parent $PSScriptRoot
$CfgPath = Join-Path $ProjRoot "godot-racer\openrouter.local.cfg"

# ── CA 证书包 ────────────────────────────────────────────────
# 为什么必须显式指定：在某些受约束的进程/沙箱里，curl 的 schannel 后端拿不到
# Windows 证书存储（报 SEC_E_NO_CREDENTIALS），表现为"CONNECT 隧道建好了、
# 但 TLS 立刻失败、HTTP=000"。给一个 CA 包文件就能绕开。
# git 在本机就是靠 .git-ca-bundle.crt 出网的，这里复用同一份。
$CaBundle = $null
foreach ($c in @(
    (Join-Path $env:USERPROFILE ".git-ca-bundle.crt"),
    (Join-Path $env:USERPROFILE "ca-bundle.crt"),
    "C:\Program Files\Git\mingw64\etc\ssl\certs\ca-bundle.crt"
)) {
    if (Test-Path $c) { $CaBundle = $c; break }
}

function Line($t) { Write-Host $t }
function Ok($t)   { Write-Host "  [OK]   $t" -ForegroundColor Green }
function Bad($t)  { Write-Host "  [FAIL] $t" -ForegroundColor Red }
function Info($t) { Write-Host "  ...    $t" -ForegroundColor DarkGray }

Line "=============================================="
Line " OpenRouter 连通性分层测试"
Line "=============================================="

# ---------- 第 0 层：读配置 ----------
Line ""
Line "[0] 读取配置"
$apiKey = $env:OPENROUTER_API_KEY
if ([string]::IsNullOrWhiteSpace($apiKey) -and (Test-Path $CfgPath)) {
    Info "从 $CfgPath 读"
    foreach ($l in Get-Content $CfgPath) {
        $t = $l.Trim()
        if ($t -eq "" -or $t.StartsWith("#") -or -not $t.Contains("=")) { continue }
        $kv = $t.Split("=", 2)
        switch ($kv[0].Trim().ToLower()) {
            "api_key" { if (-not $apiKey) { $apiKey = $kv[1].Trim() } }
            "proxy"   { if (-not $NoProxy) { $Proxy = $kv[1].Trim() } }
            "model"   { if ($Model -eq "nvidia/nemotron-3-ultra-550b-a55b:free") { $Model = $kv[1].Trim() } }
        }
    }
}
if ([string]::IsNullOrWhiteSpace($apiKey)) {
    Bad "没有找到 API key。请先创建 godot-racer\openrouter.local.cfg 并填 api_key=sk-or-v1-..."
    Bad "或设置环境变量：`$env:OPENROUTER_API_KEY = 'sk-or-v1-...'"
    exit 2
}
Ok ("API key 已读到：{0}***（{1} 字符）" -f $apiKey.Substring(0, [Math]::Min(6, $apiKey.Length)), $apiKey.Length)
Ok "模型：$Model"
if ($NoProxy) { Info "本次不使用代理（-NoProxy）" } else { Ok "代理：$Proxy" }
if ($CaBundle) { Ok "CA 证书包：$CaBundle" } else { Info "没找到 CA 包，将用系统证书链（受约束进程可能失败）" }

# ---------- 第 1 层：DNS ----------
Line ""
Line "[1] DNS 解析 openrouter.ai"
try {
    $dns = Resolve-DnsName openrouter.ai -Type A -ErrorAction Stop | Where-Object { $_.IPAddress } | Select-Object -First 3
    if ($dns) { Ok ("解析到: " + (($dns | ForEach-Object { $_.IPAddress }) -join ", ")) }
    else { Bad "解析结果为空" }
} catch { Bad "DNS 失败：$($_.Exception.Message)" }

# ---------- 第 2 层：代理端口是否在监听 ----------
Line ""
Line "[2] 本地代理端口是否在监听"
$port = 7897
$m = [regex]::Match($Proxy, ':(\d+)')
if ($m.Success) { $port = [int]$m.Groups[1].Value }
$listening = (netstat -ano | Select-String ":$port\s" | Select-String "LISTENING") -ne $null
if ($listening) { Ok "127.0.0.1:$port 正在监听（Clash Verge 内核已起）" }
else { Bad "127.0.0.1:$port 没有在监听 —— 请打开 Clash Verge 主程序并确认混合端口是 $port" }

# ---------- 第 3 层：发真实请求 ----------
Line ""
Line "[3] 向 OpenRouter 发最小请求（模型 $Model）"
$body = @{
    model = $Model
    messages = @(
        @{ role = "system"; content = "你是测试探针，只回答一个词。" }
        @{ role = "user"; content = "回复：PONG" }
    )
    max_tokens = 20
    temperature = 0
} | ConvertTo-Json -Depth 6 -Compress

$tmp = Join-Path $env:TEMP "or_test_body.json"
$resp = Join-Path $env:TEMP "or_test_resp.json"
Set-Content -Path $tmp -Value $body -Encoding utf8 -NoNewline

$curlArgs = @("-s", "-o", $resp, "-w", "%{http_code}",
          "--max-time", "$TimeoutSec",
          "-X", "POST", "https://openrouter.ai/api/v1/chat/completions",
          "-H", "Authorization: Bearer $apiKey",
          "-H", "Content-Type: application/json",
          "-H", "HTTP-Referer: http://127.0.0.1",
          "-H", "X-Title: godot-racer-test",
          "--data-binary", "@$tmp")
if ($CaBundle) { $curlArgs = @("--cacert", $CaBundle) + $curlArgs }
# 注意：不要用 $args 当变量名（那是 PowerShell 自动变量），
# 也不要写裸的 @args 当参数传递——在 Windows PowerShell 5.1 下语法不同，会解析失败。
if (-not $NoProxy) { $curlArgs = @("-x", $Proxy) + $curlArgs }

$httpCode = & curl.exe @curlArgs 2>&1
$rawResp = Get-Content $resp -Raw -ErrorAction SilentlyContinue

if ($httpCode -eq "200") {
    Ok "HTTP 200 连通！"
    try {
        $j = $rawResp | ConvertFrom-Json
        $content = $j.choices[0].message.content
        Ok "模型回复：$content"
        if ($j.usage) { Info "tokens: prompt=$($j.usage.prompt_tokens) completion=$($j.usage.completion_tokens)" }
        Line ""
        Line "=============================================="
        Line " 结论：三层全通，可以让 Godot 接入了"
        Line "=============================================="
        exit 0
    } catch { Bad "返回体不是预期 JSON：$rawResp" ; exit 3 }
}
elseif ($httpCode -eq "000") {
    Bad "curl 返回 000（没有拿到 HTTP 响应）—— 需要看具体死在哪一步，正在诊断…"
    # 关键：000 可能是"TCP 没通"、"CONNECT 被拒"、"TLS 握手失败"三件完全不同的事。
    # 用 -v 抓握手细节来区分，否则只能瞎猜（我第一版就是只报一句"连不上"）。
    $verbose = & curl.exe -v -s -o NUL --max-time $TimeoutSec -x $Proxy `
        -H "Authorization: Bearer $apiKey" https://openrouter.ai/api/v1/models 2>&1
    $tunnelOk = ($verbose | Select-String -Pattern '< HTTP/1\.[01] 200 Connection established' -Quiet)
    $tlsFail  = ($verbose | Select-String -Pattern 'SEC_E_NO_CREDENTIALS|schannel:.*failed|TLS|SSL' -Quiet)
    if ($tunnelOk -and $tlsFail) {
        Bad "代理隧道建立成功，但本进程 TLS 握手失败"
        Info "这是**运行环境**问题，不是代理问题：受约束进程拿不到系统 crypto 凭证"
        Info "证据行：$(($verbose | Select-String -Pattern 'SEC_E_NO_CREDENTIALS' | Select-Object -First 1).Line.Trim())"
        Info "绕过办法：在本机普通 PowerShell 窗口里跑本脚本，或给 curl 加 --cacert（本脚本已自动尝试）"
        exit 9
    }
    elseif ($tunnelOk) {
        Bad "隧道建立了但数据没回来（节点可能不可用，或该域名走了直连）"
        Info ($verbose | Select-Object -Last 6 | Out-String).Trim()
        exit 10
    }
    else {
        Bad "连代理本身都没成功（CONNECT 没通过）"
        Info ($verbose | Select-Object -Last 6 | Out-String).Trim()
        exit 11
    }
}
elseif ($httpCode -eq "401") {
    Bad "HTTP 401 未授权 —— key 无效或已被删除"
    Info $rawResp
    exit 5
}
elseif ($httpCode -eq "404") {
    Bad "HTTP 404 —— 模型名不存在（检查拼写，:free 后缀要带上）"
    Info $rawResp
    exit 6
}
elseif ($httpCode -eq "429") {
    Bad "HTTP 429 —— 限流/额度用尽"
    Info $rawResp
    exit 7
}
else {
    Bad "HTTP $httpCode"
    Info $rawResp
    exit 8
}
