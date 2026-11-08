#Requires -Version 5.1
<#
    离线安装 DSH 插件
    用法：
      .\dsh-install-plugin.ps1 包名 [版本]
      例：.\dsh-install-plugin.ps1 dsh-computer-use-win
          .\dsh-install-plugin.ps1 @xmanrui/dsh-im 5.10.0

    做的事：
      1. 检查 dsh 是否已退出
      2. 备份 package.json / pnpm-lock.yaml
      3. pnpm add 安装
      4. 把包名写进 package.json 的 dsh.profile.bundles
      5. 校验 electron 二进制是否完好，缺失则用镜像修复
#>

param(
    [Parameter(Mandatory = $true, Position = 0)][string]$Package,
    [Parameter(Position = 1)][string]$Version = ""
)

$ErrorActionPreference = "Stop"
$profileDir = Join-Path $env:USERPROFILE ".dsh\profiles\desktop"

function Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Fail($msg) { Write-Host $msg -ForegroundColor Red; exit 1 }

if (-not (Test-Path $profileDir)) { Fail "找不到 profile 目录：$profileDir" }

# ---------- 1. dsh 必须完全退出 ----------
$proc = Get-Process -Name "DeepSeek Harness" -ErrorAction SilentlyContinue
if ($proc) {
    Write-Host ""
    Write-Host "检测到 dsh 正在运行（$($proc.Count) 个进程）。" -ForegroundColor Red
    Write-Host "请在托盘退出 DSH，并在任务管理器确认没有 DeepSeek Harness 进程后重试。" -ForegroundColor Red
    Write-Host ""
    exit 1
}
Step "dsh 未运行，可以安装"

# ---------- 2. 备份 ----------
$stamp  = Get-Date -Format "yyyyMMdd-HHmmss"
$backup = Join-Path $profileDir "_install-backup-$stamp"
New-Item -ItemType Directory -Force -Path $backup | Out-Null
foreach ($f in @("package.json", "pnpm-lock.yaml", "cordis.patch.yml")) {
    $src = Join-Path $profileDir $f
    if (Test-Path $src) { Copy-Item $src $backup -Force }
}
Step "已备份到 $backup"

# ---------- 3. pnpm add ----------
$spec = $Package
if ($Version -ne "") { $spec = "$Package@$Version" }
Step "安装 $spec （可能需要 10-60 秒）"

# 通过 cmd /c 包一层调用 pnpm：
# PowerShell 5.1 会把原生命令的 stderr 包装成 ErrorRecord（打印出 "pnpm.cmd : ..." 的噪音），
# 经 cmd 转发后拿到的就是纯文本，既干净又保留完整错误信息。
Push-Location $profileDir
try {
    $raw  = cmd /c "pnpm add $spec --reporter=append-only 2>&1"
    $code = $LASTEXITCODE
}
finally {
    Pop-Location
}

$lines = @($raw | ForEach-Object { "$_" } | Where-Object { $_ -notmatch '^Progress:' -and $_ -ne '' })
if ($lines.Count -gt 0) { $lines | Select-Object -Last 12 }

if ($code -ne 0) {
    Write-Host ""
    Write-Host "安装失败（exit=$code）。" -ForegroundColor Red
    Write-Host "package.json 已自动回滚；如状态异常，可从 $backup 还原。" -ForegroundColor Yellow
    exit $code
}

# ---------- 4. 写入 bundles ----------
$pkgPath = Join-Path $profileDir "package.json"
$json    = Get-Content $pkgPath -Raw -Encoding UTF8 | ConvertFrom-Json
$bundles = @($json.dsh.profile.bundles)

if ($bundles -contains $Package) {
    Step "bundles 中已存在，跳过"
}
else {
    $list = New-Object System.Collections.ArrayList
    foreach ($b in $bundles) { [void]$list.Add($b) }

    # UI 包 @linxin666/dsh-web-all 习惯放在最后，新插件插在它前面
    $idx = $list.IndexOf("@linxin666/dsh-web-all")
    if ($idx -ge 0) { $list.Insert($idx, $Package) } else { [void]$list.Add($Package) }

    $json.dsh.profile.bundles = @($list)
    ($json | ConvertTo-Json -Depth 10) | Set-Content $pkgPath -Encoding UTF8
    Step "已写入 bundles（当前 $($list.Count) 项）"
}

# ---------- 5. 校验 electron 二进制 ----------
$electronDir = Join-Path $profileDir "node_modules\electron"
$electronExe = Join-Path $electronDir "dist\electron.exe"
if ((Test-Path $electronDir) -and (-not (Test-Path $electronExe))) {
    Write-Host ""
    Write-Host "警告：electron 二进制被清空了，正在用国内镜像修复..." -ForegroundColor Yellow
    Push-Location $electronDir
    $env:ELECTRON_MIRROR     = "https://npmmirror.com/mirrors/electron/"
    $env:ELECTRON_CUSTOM_DIR = "{{ version }}"
    & node install.js
    Pop-Location
    if (Test-Path $electronExe) { Step "electron 已修复" }
    else { Write-Host "electron 修复失败，请手动执行教程第 6 节" -ForegroundColor Red }
}

Write-Host ""
Write-Host "安装完成，可以启动 DSH 了。" -ForegroundColor Green
Write-Host "启动后请确认插件出现在「已安装」列表里。" -ForegroundColor Gray
