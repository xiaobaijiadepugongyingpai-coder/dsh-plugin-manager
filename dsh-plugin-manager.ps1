#Requires -Version 5.1
<#
    DSH 插件管理器 v2
    ------------------------------------------------------------
    启动即显示仪表盘，下方输入命令操作。
    支持从插件市场目录（awesome-dsh-plugin.com）搜索并安装。
    所有写操作要求 DSH 已完全退出，并自动备份配置。
#>

$ErrorActionPreference = "Stop"

$ToolsDir     = $PSScriptRoot
$ProfileDir   = Join-Path $env:USERPROFILE ".dsh\profiles\desktop"
$PkgPath      = Join-Path $ProfileDir "package.json"
$CacheDir     = Join-Path $ToolsDir ".cache"
$OutdatedFile = Join-Path $CacheDir "outdated.json"

. (Join-Path $ToolsDir "lib\catalog.ps1")

$env:ELECTRON_MIRROR     = "https://npmmirror.com/mirrors/electron/"
$env:ELECTRON_CUSTOM_DIR = "{{ version }}"

# ============ 输出 ============

function Step($m) { Write-Host "  $m" -ForegroundColor Cyan }
function Ok($m)   { Write-Host "  $m" -ForegroundColor Green }
function Warn($m) { Write-Host "  $m" -ForegroundColor Yellow }
function Err($m)  { Write-Host "  $m" -ForegroundColor Red }
function Dim($m)  { Write-Host "  $m" -ForegroundColor DarkGray }

# ============ 基础 ============

function Test-DshClosed {
    $p = Get-Process -Name "DeepSeek Harness" -ErrorAction SilentlyContinue
    if ($p) {
        Write-Host ""
        Err "检测到 dsh 正在运行（$($p.Count) 个进程）。"
        Warn "请在托盘退出 DSH，并在任务管理器确认没有 DeepSeek Harness 进程。"
        return $false
    }
    return $true
}

function Backup-Profile {
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $dir = Join-Path $ProfileDir "_install-backup-$stamp"
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    foreach ($f in @("package.json", "pnpm-lock.yaml", "cordis.patch.yml")) {
        $src = Join-Path $ProfileDir $f
        if (Test-Path $src) { Copy-Item $src $dir -Force }
    }
    Step "已备份到 $dir"
    return $dir
}

function Invoke-Pnpm($argsList) {
    # 不捕获输出：让 pnpm 直接绘制进度条。Out-Host 保证输出不进入函数返回值。
    $cmdLine = "pnpm " + ($argsList -join ' ') + " 2>&1"
    Push-Location $ProfileDir
    try {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        cmd /c $cmdLine | Out-Host
        $code = $LASTEXITCODE
        $sw.Stop()
    }
    finally { Pop-Location }
    Dim ("耗时 {0:N1} 秒" -f $sw.Elapsed.TotalSeconds)
    return $code
}

function Repair-Electron {
    $e = Join-Path $ProfileDir "node_modules\electron"
    $exe = Join-Path $e "dist\electron.exe"
    if ((Test-Path $e) -and (-not (Test-Path $exe))) {
        Warn "electron 二进制缺失，正在用国内镜像修复（约 19 秒）..."
        Push-Location $e
        try { & node install.js | Out-Null } finally { Pop-Location }
        if (Test-Path $exe) { Ok "electron 已修复" } else { Err "electron 修复失败，请参考教程「electron 二进制被清空时」一节" }
    }
}

function Get-Profile {
    return Get-Content $PkgPath -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Save-Profile($json) {
    # 不能用 Set-Content -Encoding UTF8：PS 5.1 会写入 BOM，应用解析 JSON 会失败
    $out = $json | ConvertTo-Json -Depth 10
    [System.IO.File]::WriteAllText($PkgPath, $out, (New-Object System.Text.UTF8Encoding($false)))
}

function Get-Installed {
    $json = Get-Profile
    $bundles = @($json.dsh.profile.bundles)
    $list = @()
    foreach ($dep in $json.dependencies.PSObject.Properties) {
        $list += [pscustomobject]@{
            Name    = $dep.Name
            Version = $dep.Value
            Enabled = ($bundles -contains $dep.Name)
        }
    }
    return $list
}

function Add-ToBundles($name) {
    $json = Get-Profile
    $bundles = @($json.dsh.profile.bundles)
    if ($bundles -contains $name) { Dim "bundles 中已存在"; return }
    $list = New-Object System.Collections.ArrayList
    foreach ($b in $bundles) { [void]$list.Add($b) }
    $idx = $list.IndexOf("@linxin666/dsh-web-all")
    if ($idx -ge 0) { $list.Insert($idx, $name) } else { [void]$list.Add($name) }
    $json.dsh.profile.bundles = @($list)
    Save-Profile $json
    Step "已写入 bundles（共 $($list.Count) 项）"
}

function Remove-FromBundles($name) {
    $json = Get-Profile
    $remain = @($json.dsh.profile.bundles | Where-Object { $_ -ne $name })
    $json.dsh.profile.bundles = $remain
    Save-Profile $json
    Step "已从 bundles 移除（剩 $($remain.Count) 项）"
}

# ============ 更新检查（带缓存） ============

function Get-OutdatedCache {
    if (-not (Test-Path $OutdatedFile)) { return $null }
    try { return Get-Content $OutdatedFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $null }
}

function Set-OutdatedCache($list) {
    New-Item -ItemType Directory -Force -Path $CacheDir | Out-Null
    $obj = @{ at = (Get-Date).ToString("o"); items = @($list) }
    $obj | ConvertTo-Json -Depth 5 | Set-Content $OutdatedFile -Encoding UTF8
}

function Compare-Semver($a, $b) {
    $pa = $a.Split('-'); $pb = $b.Split('-')
    $na = $pa[0].Split('.'); $nb = $pb[0].Split('.')
    for ($i = 0; $i -lt 3; $i++) {
        $x = 0; $y = 0
        if ($i -lt $na.Count) { [void][int]::TryParse($na[$i], [ref]$x) }
        if ($i -lt $nb.Count) { [void][int]::TryParse($nb[$i], [ref]$y) }
        if ($x -gt $y) { return 1 }
        if ($x -lt $y) { return -1 }
    }
    $hasA = $pa.Count -gt 1; $hasB = $pb.Count -gt 1
    if ($hasA -and -not $hasB) { return -1 }
    if (-not $hasA -and $hasB) { return 1 }
    if ($hasA -and $hasB) {
        $r = [string]::CompareOrdinal($pa[1], $pb[1])
        if ($r -gt 0) { return 1 }
        if ($r -lt 0) { return -1 }
    }
    return 0
}

function Get-LatestVersion($name) {
    $enc = $name.Replace('/', '%2F')
    try {
        $r = Invoke-RestMethod -Uri "https://registry.npmjs.org/$enc/latest" -TimeoutSec 15 -UseBasicParsing
        if ($r.version) { return $r.version }
    } catch {}
    try {
        $v = (& npm view $name version 2>$null | Select-Object -First 1)
        if ($v) { return $v.Trim() }
    } catch {}
    return $null
}

function Invoke-CheckUpdates {
    $installed = Get-Installed
    $total = $installed.Count
    Write-Host ""
    Dim "检查中（$total 个插件，约 10-20 秒）："
    Write-Host "  " -NoNewline
    $out = @()
    foreach ($p in $installed) {
        $latest = Get-LatestVersion $p.Name
        if ($latest -and (Compare-Semver $latest $p.Version) -gt 0) {
            $out += [pscustomobject]@{ name = $p.Name; current = $p.Version; latest = $latest }
            Write-Host "." -NoNewline -ForegroundColor Green
        }
        else {
            Write-Host "." -NoNewline -ForegroundColor DarkGray
        }
    }
    Write-Host ""
    Set-OutdatedCache $out
    if ($out.Count -eq 0) { Ok "所有插件都是最新版。" } else { Ok "发现 $($out.Count) 个可更新。" }
    return $out
}

# ============ 仪表盘 ============

function Show-Dashboard {
    Clear-Host
    $installed = Get-Installed
    $cache = Get-OutdatedCache
    $latestMap = @{}
    if ($cache) { foreach ($i in $cache.items) { $latestMap[$i.name] = $i.latest } }

    $enabledCount = @($installed | Where-Object { $_.Enabled }).Count
    $now = Get-Date -Format "yyyy-MM-dd HH:mm"

    Write-Host ""
    Write-Host "  DSH 插件管理器" -ForegroundColor White -NoNewline
    Write-Host ("   " + $now) -ForegroundColor DarkGray
    Write-Host ("  " + ("-" * 76)) -ForegroundColor DarkGray
    Write-Host ("  {0,-3} {1,-42} {2,-11} {3}" -f "#", "插件", "版本", "状态") -ForegroundColor DarkGray

    for ($i = 0; $i -lt $installed.Count; $i++) {
        $p = $installed[$i]
        $stateText = "启用"
        $stateColor = "Green"
        if (-not $p.Enabled) { $stateText = "未启用"; $stateColor = "DarkGray" }
        $showName = $p.Name
        if ($showName.Length -gt 42) { $showName = $showName.Substring(0, 39) + "..." }
        Write-Host ("  {0,-3} {1,-42} {2,-11} " -f ($i + 1), $showName, $p.Version) -NoNewline
        Write-Host $stateText -ForegroundColor $stateColor -NoNewline
        if ($latestMap.ContainsKey($p.Name)) {
            Write-Host ("  → " + $latestMap[$p.Name]) -ForegroundColor Yellow
        }
        else { Write-Host "" }
    }

    Write-Host ("  " + ("-" * 76)) -ForegroundColor DarkGray
    $upd = ""
    if ($cache) {
        $days = [math]::Round(((Get-Date) - [datetime]::Parse($cache.at)).TotalDays, 1)
        if (@($cache.items).Count -gt 0) { $upd = " · $(@($cache.items).Count) 个可更新（$days 天前检查）" }
        else { $upd = " · 已是最新（$days 天前检查）" }
    }
    else { $upd = " · 未检查更新" }
    Write-Host ("  {0} 个插件 · {1} 启用 · {2} 未启用{3}" -f $installed.Count, $enabledCount, ($installed.Count - $enabledCount), $upd) -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  help 查看命令 · q 退出" -ForegroundColor DarkGray
    Write-Host ""
}

# ============ 安装 ============

function Install-One($npmName, $version) {
    if (-not (Test-DshClosed)) { return }
    $installed = Get-Installed
    $existing = $installed | Where-Object { $_.Name -eq $npmName }
    if ($existing) {
        Warn "该插件已安装（$($existing.Version)）。如需更新请用 u 命令。"
        return
    }

    [void](Backup-Profile)
    $spec = $npmName
    if ($version) { $spec = "$npmName@$version" }
    Step "安装 $spec"
    $code = Invoke-Pnpm @("add", $spec, "--save-exact")
    if ($code -ne 0) { Err "安装失败（exit=$code），package.json 已回滚。"; return }
    Add-ToBundles $npmName
    Repair-Electron
    Ok "安装完成，重启 DSH 生效。"
}

function Do-SearchInstall($keyword) {
    if ([string]::IsNullOrWhiteSpace($keyword)) {
        $keyword = Read-Host "  输入关键词（如 sidebar / pet / theme）"
    }
    if ([string]::IsNullOrWhiteSpace($keyword)) { return }

    $ok = Update-Catalog $CacheDir $false
    if (-not $ok) { return }

    $lines = Get-CatalogLines $CacheDir
    $meta = Get-CatalogMeta $CacheDir
    $results = Search-Catalog $lines $keyword 20

    if ($results.Count -eq 0) {
        Warn "没有匹配「$keyword」的可安装插件。"
        Dim "提示：部分插件只在 GitHub 发布，无法通过 npm 安装。"
        return
    }

    $installedNames = @(Get-Installed | ForEach-Object { $_.Name })
    $metaDate = "未知"
    if ($meta -and $meta.at) { $metaDate = $meta.at.Substring(0, 10) }
    $metaCount = 0
    if ($meta) { $metaCount = $meta.count }

    Write-Host ""
    Write-Host ("  找到 {0} 个结果（目录 {1} · 共 {2} 个可安装）" -f $results.Count, $metaDate, $metaCount) -ForegroundColor DarkGray
    Write-Host ""
    for ($i = 0; $i -lt $results.Count; $i++) {
        $r = $results[$i]
        Write-Host ("  [{0,2}] {1,-40} {2,-10}" -f ($i + 1), $r.Npm, $r.Ver) -NoNewline
        if ($installedNames -contains $r.Npm) { Write-Host "  ★已装" -ForegroundColor Green } else { Write-Host "" }
        if ($r.Desc) { Write-Host ("       " + $r.Desc) -ForegroundColor DarkGray }
    }
    Write-Host ""

    $sel = Read-Host "  输入序号安装（回车取消，k 换关键词）"
    if ([string]::IsNullOrWhiteSpace($sel)) { return }
    if ($sel -eq "k" -or $sel -eq "K") {
        $kw2 = Read-Host "  新关键词"
        Do-SearchInstall $kw2
        return
    }

    $idx = 0
    if (-not [int]::TryParse($sel.Trim(), [ref]$idx)) { Err "无效序号"; return }
    if ($idx -lt 1 -or $idx -gt $results.Count) { Err "序号超出范围"; return }

    $pick = $results[$idx - 1]
    Write-Host ""
    Write-Host "  将安装：" -NoNewline
    Write-Host $pick.Npm -ForegroundColor White
    if ($pick.Desc) { Dim $pick.Desc }
    $ans = Read-Host "  确认？(y/N)"
    if ($ans -ne "y" -and $ans -ne "Y") { Dim "已取消"; return }
    Install-One $pick.Npm $null
}

# ============ 更新 ============

function Update-One($index) {
    $installed = Get-Installed
    if ($index -lt 1 -or $index -gt $installed.Count) { Err "序号超出范围"; return }
    $p = $installed[$index - 1]
    $latest = Get-LatestVersion $p.Name
    if (-not $latest) { Err "查询最新版本失败"; return }
    if ((Compare-Semver $latest $p.Version) -le 0) { Ok "$($p.Name) 已是最新（$($p.Version)）。"; return }

    if (-not (Test-DshClosed)) { return }
    [void](Backup-Profile)
    Step "更新 $($p.Name)  $($p.Version) → $latest"
    $code = Invoke-Pnpm @("add", "$($p.Name)@$latest", "--save-exact")
    if ($code -ne 0) { Err "更新失败（exit=$code）"; return }
    Repair-Electron
    Ok "更新完成。"
}

function Update-All {
    $cache = Get-OutdatedCache
    $count = 0
    if ($cache) { $count = @($cache.items).Count }
    if ($count -eq 0) {
        Dim "先检查一次更新..."
        $fresh = Invoke-CheckUpdates
        $count = @($fresh).Count
    }
    if ($count -eq 0) { Ok "没有可更新的插件。"; return }

    Warn "即将更新 $count 个插件。更新后如不兼容可能导致启动异常（可用备份还原）。"
    $ans = Read-Host "  确认？(y/N)"
    if ($ans -ne "y" -and $ans -ne "Y") { return }
    if (-not (Test-DshClosed)) { return }
    [void](Backup-Profile)
    Step "执行 pnpm up --latest"
    $code = Invoke-Pnpm @("up", "--latest")
    if ($code -ne 0) { Err "更新失败（exit=$code）"; return }
    Repair-Electron
    [void](Invoke-CheckUpdates)
    Ok "更新完成。"
}

function Handle-Update($arg) {
    if ([string]::IsNullOrWhiteSpace($arg)) {
        Err "用法：u <序号> 或 u all"
        return
    }
    if ($arg.ToLower() -eq "all") { Update-All; return }
    if ($arg -match '^\d+$') { Update-One ([int]$arg); return }
    Err "参数无效：$arg（应为序号或 all）"
}

# ============ 卸载 ============

function Get-PluginDataPaths($name) {
    $dshHome = Join-Path $env:USERPROFILE ".dsh"
    $base = $name.Split('/')[-1]
    $protected = @('profiles','storages','skills','logs','dsh-session-archive',
                   'dsh-usage','dsh-agents','task-board','bin','cache','tools','node_modules','.cache')
    $paths = @()
    if ($protected -notcontains $base) {
        $p = Join-Path $dshHome $base
        if (Test-Path $p) { $paths += $p }
    }
    $extra = @{ 'dsh-pet' = @('pet.json', 'pets') }
    if ($extra.ContainsKey($base)) {
        foreach ($x in $extra[$base]) {
            $p = Join-Path $dshHome $x
            if ((Test-Path $p) -and ($paths -notcontains $p)) { $paths += $p }
        }
    }
    return $paths
}

function Remove-PluginData($name) {
    $paths = Get-PluginDataPaths $name
    if ($paths.Count -eq 0) { Dim "未发现该插件的独立数据目录。"; return }

    Write-Host ""
    Warn "该插件在 ~/.dsh 下还有数据："
    foreach ($p in $paths) {
        $sum = (Get-ChildItem $p -Recurse -File -Force -ErrorAction SilentlyContinue |
                Measure-Object -Property Length -Sum).Sum
        if (-not $sum) { $sum = 0 }
        Dim ("{0}  ({1:N1} MB)" -f $p.Replace($env:USERPROFILE, '~'), ($sum / 1MB))
    }
    Dim "删除后重装会回到初始状态；保留则配置仍在。"
    Dim "安全措施：只移动到 ~/.dsh/_uninstall-trash-时间戳\，可随时取回。"
    $ans = Read-Host "  删除这些数据？(y/N)"
    if ($ans -ne "y" -and $ans -ne "Y") { Dim "已保留数据。"; return }

    Warn "二次确认：请输入完整包名 $name"
    $confirm = Read-Host "  请输入"
    if ($confirm -ne $name) { Warn "输入不匹配，已跳过（数据保留）。"; return }

    $trash = Join-Path (Join-Path $env:USERPROFILE ".dsh") ("_uninstall-trash-" + (Get-Date -Format "yyyyMMdd-HHmmss"))
    New-Item -ItemType Directory -Force -Path $trash | Out-Null
    foreach ($p in $paths) {
        $leaf = Split-Path $p -Leaf
        try {
            Move-Item -LiteralPath $p -Destination (Join-Path $trash $leaf) -Force -ErrorAction Stop
            Step "已移入回收目录：$leaf"
        }
        catch { Err "移动失败：$leaf" }
    }
    Ok "数据已移到 $trash"
}

function Remove-One($index, $skipConfirm) {
    $installed = Get-Installed
    if ($index -lt 1 -or $index -gt $installed.Count) { Err "序号超出范围"; return }
    $p = $installed[$index - 1]

    if (-not $skipConfirm) {
        Write-Host ""
        Warn "即将卸载：$($p.Name)  ($($p.Version))"
        $ans = Read-Host "  确认？(y/N)"
        if ($ans -ne "y" -and $ans -ne "Y") { return }
    }
    if (-not (Test-DshClosed)) { return }
    [void](Backup-Profile)

    Step "卸载 $($p.Name)"
    $code = Invoke-Pnpm @("remove", $p.Name)
    if ($code -ne 0) { Err "卸载失败（exit=$code）"; return }
    Remove-FromBundles $p.Name
    Remove-PluginData $p.Name
    Repair-Electron
    Ok "卸载完成。"
}

function Handle-Remove($arg) {
    if ([string]::IsNullOrWhiteSpace($arg)) {
        Err "用法：rm <序号,...>  例如 rm 3,5"
        return
    }
    $idxList = @()
    foreach ($x in $arg.Split(',')) {
        $t = $x.Trim()
        if ($t -match '^\d+$') { $idxList += [int]$t }
    }
    if ($idxList.Count -eq 0) { Err "参数无效：$arg"; return }

    $installed = Get-Installed
    $names = @()
    foreach ($i in $idxList) {
        if ($i -ge 1 -and $i -le $installed.Count) { $names += $installed[$i - 1].Name }
    }
    if ($names.Count -eq 0) { Err "序号超出范围"; return }

    Write-Host ""
    Warn ("即将卸载 {0} 个插件：{1}" -f $names.Count, ($names -join ', '))
    $ans = Read-Host "  确认？(y/N)"
    if ($ans -ne "y" -and $ans -ne "Y") { return }

    foreach ($i in $idxList) { Remove-One $i $true }
}

# ============ 详情 / 单插件菜单 ============

function Show-PluginInfo($index) {
    $installed = Get-Installed
    if ($index -lt 1 -or $index -gt $installed.Count) { Err "序号超出范围"; return }
    $p = $installed[$index - 1]
    $dir = Join-Path $ProfileDir "node_modules\$($p.Name)"

    Write-Host ""
    Write-Host "  $($p.Name)" -ForegroundColor White
    Write-Host ("  " + ("-" * 62)) -ForegroundColor DarkGray
    Write-Host "  版本    " -NoNewline; Write-Host $p.Version
    Write-Host "  状态    " -NoNewline
    if ($p.Enabled) { Write-Host "启用" -ForegroundColor Green } else { Write-Host "未启用" -ForegroundColor DarkGray }

    $pj = Join-Path $dir "package.json"
    if (Test-Path $pj) {
        try {
            $meta = Get-Content $pj -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($meta.description) { Write-Host "  描述    " -NoNewline; Write-Host $meta.description }
            if ($meta.repository -and $meta.repository.url) { Write-Host "  仓库    " -NoNewline; Write-Host $meta.repository.url }
        } catch {}
    }
    $dataPaths = Get-PluginDataPaths $p.Name
    if ($dataPaths.Count -gt 0) { Write-Host "  数据    " -NoNewline; Write-Host ($dataPaths -join " ; ") }
    Write-Host ""
}

function Select-Plugin($index) {
    $installed = Get-Installed
    if ($index -lt 1 -or $index -gt $installed.Count) { Err "序号超出范围"; return }
    $p = $installed[$index - 1]

    Write-Host ""
    Write-Host ("  已选中：{0}  {1}" -f $p.Name, $p.Version) -ForegroundColor White
    Write-Host "  [1] 更新   [2] 卸载   [3] 详情   [b] 返回" -ForegroundColor DarkGray
    $sel = Read-Host "  选择"
    switch ($sel.Trim()) {
        "1" { Update-One $index; [void](Read-Host "  回车继续") }
        "2" { Remove-One $index $false; [void](Read-Host "  回车继续") }
        "3" { Show-PluginInfo $index; [void](Read-Host "  回车继续") }
        default { return }
    }
}

# ============ 帮助 ============

function Show-Help {
    Write-Host ""
    Write-Host "  命令" -ForegroundColor White
    Write-Host ("  " + ("-" * 62)) -ForegroundColor DarkGray
    Write-Host "  i <关键词>      搜索插件目录并安装"
    Write-Host "  u <序号>        更新指定插件      u all  更新全部"
    Write-Host "  rm <序号,...>   卸载，例如 rm 3,5"
    Write-Host "  info <序号>     查看插件详情"
    Write-Host "  check           检查可更新插件（联网约 20 秒）"
    Write-Host "  refresh         刷新插件目录缓存（约 60 秒）"
    Write-Host "  ls              重绘仪表盘"
    Write-Host "  <数字>          选中该插件，弹出操作菜单"
    Write-Host "  q               退出"
    Write-Host ""
    Dim "插件目录缓存 7 天，过期会自动提示刷新。"
    Write-Host ""
}

# ============ 主循环 ============

if (-not (Test-Path $PkgPath)) { Err "找不到 profile：$ProfileDir"; exit 1 }

while ($true) {
    Show-Dashboard
    $line = Read-Host "  >"
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    $line = $line.Trim()
    $parts = @($line -split '\s+', 2)
    $cmd = $parts[0].ToLower()
    $arg = ""
    if ($parts.Count -gt 1) { $arg = $parts[1].Trim() }

    switch ($cmd) {
        "help" { Show-Help; [void](Read-Host "  回车继续") }
        "?"    { Show-Help; [void](Read-Host "  回车继续") }
        "h"    { Show-Help; [void](Read-Host "  回车继续") }

        "ls"   { continue }
        "list" { continue }

        "check"   { [void](Invoke-CheckUpdates); [void](Read-Host "  回车继续") }
        "refresh" { [void](Update-Catalog $CacheDir $true); [void](Read-Host "  回车继续") }

        "i"       { Do-SearchInstall $arg; [void](Read-Host "  回车继续") }
        "install" { Do-SearchInstall $arg; [void](Read-Host "  回车继续") }
        "add"     { Do-SearchInstall $arg; [void](Read-Host "  回车继续") }

        "u"      { Handle-Update $arg; [void](Read-Host "  回车继续") }
        "update" { Handle-Update $arg; [void](Read-Host "  回车继续") }
        "up"     { Handle-Update $arg; [void](Read-Host "  回车继续") }

        "rm"        { Handle-Remove $arg; [void](Read-Host "  回车继续") }
        "remove"    { Handle-Remove $arg; [void](Read-Host "  回车继续") }
        "uninstall" { Handle-Remove $arg; [void](Read-Host "  回车继续") }

        "info" {
            if ($arg -match '^\d+$') { Show-PluginInfo ([int]$arg); [void](Read-Host "  回车继续") }
            else { Err "用法：info <序号>" }
        }

        "q"    { Clear-Host; return }
        "quit" { Clear-Host; return }
        "exit" { Clear-Host; return }

        default {
            if ($cmd -match '^\d+$') { Select-Plugin ([int]$cmd) }
            else {
                Err "未知命令：$cmd（输入 help 查看）"
                Start-Sleep -Milliseconds 800
            }
        }
    }
}
