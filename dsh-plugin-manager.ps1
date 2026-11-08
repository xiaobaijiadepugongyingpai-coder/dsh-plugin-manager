#Requires -Version 5.1
<#
    DSH 插件管理器 v2
    ------------------------------------------------------------
    启动即显示仪表盘，下方输入命令操作。
    支持从插件市场目录（awesome-dsh-plugin.com）搜索并安装。
    所有写操作要求 DSH 已完全退出，并自动备份配置。

    用法:
        .\dsh-plugin-manager.ps1               # 默认操作 desktop profile
        .\dsh-plugin-manager.ps1 -Profile web  # 操作其它 profile
#>

param(
    [string]$Profile = "desktop"
)

$ErrorActionPreference = "Stop"

$ToolsDir     = $PSScriptRoot
$ProfileDir   = Join-Path $env:USERPROFILE ".dsh\profiles\$Profile"
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

    # 兜底：进程名可能改名或装了便携版，直接测 node_modules 是否可写
    $nm = Join-Path $ProfileDir "node_modules"
    if (Test-Path $nm) {
        $probe = Join-Path $nm (".dsh-write-probe-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
        try {
            [System.IO.File]::WriteAllText($probe, "x")
            Remove-Item $probe -Force -ErrorAction SilentlyContinue
        }
        catch {
            Write-Host ""
            Err "node_modules 不可写，可能有进程仍占用着它。"
            Warn "请确认 DSH 已完全退出后重试。"
            return $false
        }
    }
    return $true
}

function Backup-Profile {
    $stamp = Get-Date -Format "yyyyMMdd-HHmmssfff"
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
    Write-JsonNoBom $OutdatedFile $obj
}

function Clear-OutdatedCache {
    # 安装/更新/卸载后调用：让下次绘制仪表盘或启动时重新检查，
    # 否则会继续显示 6 小时前的旧数据，与实际情况不符。
    Remove-Item $OutdatedFile -Force -ErrorAction SilentlyContinue
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
    $failed = 0
    foreach ($p in $installed) {
        $latest = Get-LatestVersion $p.Name
        if ($null -eq $latest) {
            $failed++
            Write-Host "?" -NoNewline -ForegroundColor Red
            continue
        }
        if ((Compare-Semver $latest $p.Version) -gt 0) {
            $out += [pscustomobject]@{ name = $p.Name; current = $p.Version; latest = $latest }
            Write-Host "." -NoNewline -ForegroundColor Green
        }
        else {
            Write-Host "." -NoNewline -ForegroundColor DarkGray
        }
    }
    Write-Host ""
    Set-OutdatedCache $out
    if ($failed -gt 0) {
        Warn "$failed 个插件查询失败（网络问题），结果可能不完整。"
    }
    if ($out.Count -eq 0) { Ok "已检查的插件都是最新版。" } else { Ok "发现 $($out.Count) 个可更新。" }
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
    Clear-OutdatedCache
    Ok "安装完成，重启 DSH 生效。"
    Dim "插件列表已变化，输入 ls 刷新仪表盘。"
}

function Do-SearchInstall($keyword) {
    # 用循环而不是递归：连按 k 换关键词时不会层层叠加栈帧
    while ($true) {
        if ([string]::IsNullOrWhiteSpace($keyword)) {
            $keyword = Read-Host "  输入关键词（如 sidebar / pet / theme）"
        }
        if ([string]::IsNullOrWhiteSpace($keyword)) { return }

        # 容错：用户可能照着文档写了 <关键词> 或加了引号，去掉这些符号
        $keyword = ($keyword -replace '[<>"'']', '').Trim()
        if ($keyword -eq "") { Err "关键词为空"; return }

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
            if ($r.Url) { Write-Host ("       " + $r.Url) -ForegroundColor DarkCyan }
        }
        Write-Host ""

        $sel = Read-Host "  输入序号安装（回车取消，k 换关键词）"
        if ([string]::IsNullOrWhiteSpace($sel)) { return }
        if ($sel -eq "k" -or $sel -eq "K") {
            $keyword = Read-Host "  新关键词"
            continue
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
        return
    }
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
    Clear-OutdatedCache
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
        Err "用法：u 序号 / u 包名 / u all"
        return
    }
    if ($arg.ToLower() -eq "all") { Update-All; return }
    $idx = Resolve-PluginIndex $arg
    if ($idx -gt 0) { Update-One $idx; return }
    if ($idx -eq -1) { Err "未找到插件：$arg" }
}

# ============ 卸载 ============

function Get-PathSize($path) {
    # 坑：对「文件」路径用 Get-ChildItem -Recurse，PowerShell 会递归枚举它的父目录。
    # 在 ~/.dsh 下父目录含整个 node_modules，实测一个 886 字节的文件要跑 27 秒。
    # 所以必须区分文件与目录。
    try {
        $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
    }
    catch { return [int64]0 }

    if (-not $item.PSIsContainer) { return [int64]$item.Length }

    $sum = (Get-ChildItem -LiteralPath $path -Recurse -File -Force -ErrorAction SilentlyContinue |
            Measure-Object -Property Length -Sum).Sum
    if ($sum) { return [int64]$sum }
    return [int64]0
}

function Get-PluginDataPaths($name) {
    $dshHome = Join-Path $env:USERPROFILE ".dsh"
    $base = $name.Split('/')[-1]
    $protected = @('profiles','storages','skills','logs','dsh-session-archive',
                   'dsh-usage','dsh-agents','task-board','bin','cache','tools','node_modules','.cache')
    $paths = @()
    if ($protected -notcontains $base) {
        $p = Join-Path $dshHome $base
        if (Test-Path $p) { $paths += [pscustomobject]@{ Path = $p; Reason = "与包名末段同名" } }
    }
    $extra = @{ 'dsh-pet' = @('pet.json', 'pets') }
    if ($extra.ContainsKey($base)) {
        foreach ($x in $extra[$base]) {
            $p = Join-Path $dshHome $x
            $exists = @($paths | Where-Object { $_.Path -eq $p }).Count -gt 0
            if ((Test-Path $p) -and (-not $exists)) {
                $paths += [pscustomobject]@{ Path = $p; Reason = "已知映射（dsh-pet 专用）" }
            }
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
        $sum = Get-PathSize $p.Path
        Dim ("{0}  ({1:N1} MB)  ← {2}" -f $p.Path.Replace($env:USERPROFILE, '~'), ($sum / 1MB), $p.Reason)
    }
    Dim "删除后重装会回到初始状态；保留则配置仍在。"
    Dim "安全措施：只移动到 ~/.dsh/_uninstall-trash-时间戳\，可随时取回。"
    $ans = Read-Host "  删除这些数据？(y/N)"
    if ($ans -ne "y" -and $ans -ne "Y") { Dim "已保留数据。"; return }

    Warn "二次确认：请输入完整包名 $name"
    $confirm = Read-Host "  请输入"
    if ($confirm -ne $name) { Warn "输入不匹配，已跳过（数据保留）。"; return }

    $trash = Join-Path (Join-Path $env:USERPROFILE ".dsh") ("_uninstall-trash-" + (Get-Date -Format "yyyyMMdd-HHmmssfff"))
    New-Item -ItemType Directory -Force -Path $trash | Out-Null
    foreach ($p in $paths) {
        $leaf = Split-Path $p.Path -Leaf
        try {
            Move-Item -LiteralPath $p.Path -Destination (Join-Path $trash $leaf) -Force -ErrorAction Stop
            Step "已移入回收目录：$leaf"
        }
        catch { Err "移动失败：$leaf" }
    }
    Ok "数据已移到 $trash"
}

function Get-PluginPatchIds($name) {
    # 插件自己的 cordis.patch.yml 声明了它会插入哪些条目 id。
    # 必须在 pnpm remove 之前读取——删掉包之后就查不到了。
    $p = Join-Path $ProfileDir "node_modules\$name\cordis.patch.yml"
    if (-not (Test-Path $p)) { return @() }
    $ids = @()
    foreach ($line in (Get-Content $p -Encoding UTF8)) {
        if ($line -match '^\s*-\s*id:\s*(.+)$') {
            $ids += $matches[1].Trim().Trim("'").Trim('"')
        }
    }
    return @($ids | Select-Object -Unique)
}

function Get-TopLevelPatchIds($lines) {
    $out = @()
    foreach ($l in $lines) {
        if ($l -match '^- id:\s*(.+)$') {
            $out += $matches[1].Trim().Trim("'").Trim('"')
        }
    }
    return $out
}

function Remove-PluginConfig($name, $ids) {
    if ($ids.Count -eq 0) { Dim "未找到该插件的配置条目声明，跳过配置清理。"; return }

    $patchPath = Join-Path $ProfileDir "cordis.patch.yml"
    if (-not (Test-Path $patchPath)) { return }

    $lines = @(Get-Content $patchPath -Encoding UTF8)
    $starts = @()
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^- id:\s*(.+)$') {
            $starts += [pscustomobject]@{ Line = $i; Id = $matches[1].Trim().Trim("'").Trim('"') }
        }
    }

    $targets = @()
    for ($k = 0; $k -lt $starts.Count; $k++) {
        if ($ids -contains $starts[$k].Id) {
            $end = $lines.Count - 1
            if ($k + 1 -lt $starts.Count) { $end = $starts[$k + 1].Line - 1 }
            $targets += [pscustomobject]@{ Id = $starts[$k].Id; Start = $starts[$k].Line; End = $end }
        }
    }
    if ($targets.Count -eq 0) { Dim "配置文件里没有该插件的条目（可能从未配置过）。"; return }

    Write-Host ""
    Warn "该插件在 cordis.patch.yml 里还有 $($targets.Count) 条配置："
    foreach ($t in $targets) {
        Dim ("  - id: {0}   （第 {1}-{2} 行，共 {3} 行）" -f $t.Id, ($t.Start + 1), ($t.End + 1), ($t.End - $t.Start + 1))
    }
    Dim "只删除这些条目，其它插件的配置不会动。"
    $ans = Read-Host "  删除这些配置？(y/N)"
    if ($ans -ne "y" -and $ans -ne "Y") { Dim "已保留配置。"; return }

    # 按整块剔除
    $drop = @{}
    foreach ($t in $targets) {
        for ($i = $t.Start; $i -le $t.End; $i++) { $drop[$i] = $true }
    }
    $newLines = @()
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if (-not $drop.ContainsKey($i)) { $newLines += $lines[$i] }
    }

    # 删除前校验：除目标外，其它条目必须一条不少
    $before = @(Get-TopLevelPatchIds $lines)
    $expected = @($before | Where-Object { $ids -notcontains $_ })
    $got = @(Get-TopLevelPatchIds $newLines)
    if ((($got | Sort-Object) -join "|") -ne (($expected | Sort-Object) -join "|")) {
        Err "预校验失败：删除后条目与预期不符，已放弃修改。"
        return
    }

    $bak = "$patchPath.bak-" + (Get-Date -Format "yyyyMMdd-HHmmssfff")
    Copy-Item $patchPath $bak -Force
    $text = ($newLines -join "`r`n") + "`r`n"
    [System.IO.File]::WriteAllText($patchPath, $text, (New-Object System.Text.UTF8Encoding($false)))

    # 写入后再校验一次，不对就回滚
    $after = @(Get-TopLevelPatchIds (Get-Content $patchPath -Encoding UTF8))
    if ((($after | Sort-Object) -join "|") -ne (($expected | Sort-Object) -join "|")) {
        Copy-Item $bak $patchPath -Force
        Err "写入后校验失败，已从备份回滚。"
        return
    }

    Ok "已删除 $($targets.Count) 条配置（备份：$(Split-Path $bak -Leaf)）"
    Dim "剩余 $($after.Count) 条，其它插件配置完好。"
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

    # 必须在删除包之前读取：插件目录里的 cordis.patch.yml 声明了它的配置条目
    $patchIds = Get-PluginPatchIds $p.Name

    Step "卸载 $($p.Name)"
    $code = Invoke-Pnpm @("remove", $p.Name)
    if ($code -ne 0) { Err "卸载失败（exit=$code）"; return }
    Remove-FromBundles $p.Name
    Remove-PluginData $p.Name
    Remove-PluginConfig $p.Name $patchIds
    Repair-Electron
    Clear-OutdatedCache
    Ok "卸载完成。"
    Dim "插件列表已变化，输入 ls 刷新仪表盘。"
}

function Handle-Remove($arg) {
    if ([string]::IsNullOrWhiteSpace($arg)) {
        Err "用法：rm 3,5  或  rm 包名1,包名2"
        return
    }
    $idxList = @()
    foreach ($x in $arg.Split(',')) {
        $t = $x.Trim()
        if ($t -eq "") { continue }
        $r = Resolve-PluginIndex $t
        if ($r -gt 0) { $idxList += $r }
        elseif ($r -eq -1) { Warn "未找到：$t" }
    }
    if ($idxList.Count -eq 0) { Err "没有可卸载的插件"; return }

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

# ============ 启动 DSH ============

function Get-DshExe {
    # 1. 用户手动指定过
    $cfgFile = Join-Path $CacheDir "config.json"
    if (Test-Path $cfgFile) {
        try {
            $cfg = Get-Content $cfgFile -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($cfg.dshExe -and (Test-Path $cfg.dshExe)) { return $cfg.dshExe }
        }
        catch {}
    }

    # 2. 注册表卸载项（最可靠，跨机器通用）
    $keys = @(
        "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )
    foreach ($k in $keys) {
        $items = Get-ItemProperty $k -ErrorAction SilentlyContinue |
                 Where-Object { $_.DisplayName -match "^DeepSeek Harness" }
        foreach ($it in $items) {
            if ($it.DisplayIcon) {
                $exe = ($it.DisplayIcon -split ",")[0].Trim()
                if (Test-Path $exe) { return $exe }
            }
            if ($it.InstallLocation) {
                $exe = Join-Path $it.InstallLocation "DeepSeek Harness.exe"
                if (Test-Path $exe) { return $exe }
            }
        }
    }

    # 3. 正在运行的进程
    $proc = Get-Process -Name "DeepSeek Harness" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($proc -and $proc.Path) { return $proc.Path }

    return $null
}

function Save-DshExe($path) {
    New-Item -ItemType Directory -Force -Path $CacheDir | Out-Null
    $cfgFile = Join-Path $CacheDir "config.json"
    Write-JsonNoBom $cfgFile @{ dshExe = $path }
}

function Start-Dsh {
    $running = Get-Process -Name "DeepSeek Harness" -ErrorAction SilentlyContinue
    if ($running) { Warn "DSH 已经在运行（$($running.Count) 个进程）。"; return }

    $exe = Get-DshExe
    if (-not $exe) {
        Warn "没找到 DSH 的安装位置。"
        $typed = Read-Host "  请输入 DeepSeek Harness.exe 的完整路径（回车取消）"
        if ([string]::IsNullOrWhiteSpace($typed)) { return }
        $typed = $typed.Trim().Trim('"')
        if (-not (Test-Path $typed)) { Err "路径不存在：$typed"; return }
        Save-DshExe $typed
        $exe = $typed
        Dim "已记住该路径，下次自动使用。"
    }

    try {
        Start-Process -FilePath $exe -WorkingDirectory (Split-Path $exe -Parent)
        Ok "已启动：$exe"
        Dim "启动需要几秒，插件加载完成后即可使用。"
    }
    catch { Err "启动失败：$($_.Exception.Message)" }
}

# ============ 详情 + 操作（合并） ============

function Resolve-PluginIndex($token) {
    # 返回 1..N 表示找到；0 表示匹配到多个；-1 表示没找到
    $installed = Get-Installed
    if ($token -match '^\d+$') {
        $n = [int]$token
        if ($n -ge 1 -and $n -le $installed.Count) { return $n }
        return -1
    }

    for ($i = 0; $i -lt $installed.Count; $i++) {
        if ($installed[$i].Name -eq $token) { return ($i + 1) }
    }

    $partial = @()
    for ($i = 0; $i -lt $installed.Count; $i++) {
        # 用 IndexOf 而非 -like：用户输入里的 * ? 会被当通配符，可能误匹配到别的插件
        if ($installed[$i].Name.IndexOf($token, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
            $partial += ($i + 1)
        }
    }
    if ($partial.Count -eq 1) { return $partial[0] }
    if ($partial.Count -gt 1) {
        Warn "「$token」匹配到多个插件："
        foreach ($n in $partial) { Dim ("[{0}] {1}" -f $n, $installed[$n - 1].Name) }
        Dim "请用序号或完整包名指定。"
        return 0
    }
    return -1
}

function Show-PluginDetail($index) {
    $installed = Get-Installed
    if ($index -lt 1 -or $index -gt $installed.Count) { Err "序号超出范围"; return }
    $p = $installed[$index - 1]
    $dir = Join-Path $ProfileDir "node_modules\$($p.Name)"

    $desc = ""
    $repo = ""
    $pj = Join-Path $dir "package.json"
    if (Test-Path $pj) {
        try {
            $m = Get-Content $pj -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($m.description) { $desc = $m.description }
            if ($m.repository -and $m.repository.url) {
                # npm 里的仓库地址常写成 git+https://xxx.git，浏览器打不开，转成普通 https
                $repo = $m.repository.url
                $repo = $repo -replace '^git\+', ''
                $repo = $repo -replace '^git://', 'https://'
                $repo = $repo -replace '\.git$', ''
            }
        } catch {}
    }

    $latest = ""
    $cache = Get-OutdatedCache
    if ($cache) {
        foreach ($i in $cache.items) { if ($i.name -eq $p.Name) { $latest = $i.latest } }
    }

    Write-Host ""
    Write-Host "  $($p.Name)" -ForegroundColor White -NoNewline
    Write-Host ("  " + $p.Version) -ForegroundColor Gray -NoNewline
    if ($p.Enabled) { Write-Host "  启用" -ForegroundColor Green } else { Write-Host "  未启用" -ForegroundColor DarkGray }
    Write-Host ("  " + ("-" * 66)) -ForegroundColor DarkGray

    if ($desc) { Write-Host "  描述  " -NoNewline; Write-Host $desc }
    if ($repo) { Write-Host "  仓库  " -NoNewline; Write-Host $repo -ForegroundColor Cyan }

    $dataPaths = Get-PluginDataPaths $p.Name
    if ($dataPaths.Count -gt 0) {
        $total = 0
        foreach ($d in $dataPaths) { $total += (Get-PathSize $d.Path) }
        $shown = @($dataPaths | ForEach-Object { $_.Path.Replace($env:USERPROFILE, '~') })
        Write-Host "  数据  " -NoNewline
        Write-Host (($shown -join " ; ") + ("  ({0:N1} MB)" -f ($total / 1MB)))
    }

    if ($latest) {
        Write-Host "  最新  " -NoNewline
        Write-Host ("$latest  可更新") -ForegroundColor Yellow
    }

    Write-Host ""
    Write-Host "  [1] 更新   [2] 卸载   [3] 打开仓库   [b] 返回" -ForegroundColor DarkGray
    $sel = Read-Host "  选择"
    switch ($sel.Trim()) {
        "1" { Update-One $index }
        "2" { Remove-One $index $false }
        "3" {
            if ($repo) {
                # 仓库地址来自插件 package.json，恶意插件可能写任意协议，只放行 http(s)
                if ($repo -match '^https?://') {
                    Start-Process $repo
                    Dim "已在浏览器打开：$repo"
                }
                else { Warn "仓库地址格式异常，已跳过：$repo" }
            }
            else { Warn "该插件未声明仓库地址" }
        }
        default { return }
    }
}

# ============ 帮助 ============

function Show-Help {
    Write-Host ""
    Write-Host "  命令（参数直接跟在后面，不要加尖括号）" -ForegroundColor White
    Write-Host ("  " + ("-" * 62)) -ForegroundColor DarkGray
    Write-Host "  i 关键词       搜索并安装，例如：i sidebar"
    Write-Host "  3              查看第 3 个插件（详情 + 操作菜单）"
    Write-Host "  dsh-pet        也可以直接输包名查看"
    Write-Host "  u 3            更新第 3 个插件（同样支持包名）"
    Write-Host "  u all          更新全部"
    Write-Host "  rm 3,5         批量卸载"
    Write-Host "  start          启动 DSH（自动定位安装路径）"
    Write-Host "  refresh        刷新插件目录缓存（约 60 秒）"
    Write-Host "  check          立即检查更新（启动时会自动检查，通常不需要）"
    Write-Host "  ls             重绘仪表盘"
    Write-Host "  q              退出"
    Write-Host ""
    Dim "插件目录缓存 7 天，过期会自动提示刷新。"
    Write-Host ""
}

# ============ 主循环 ============

if (-not (Test-Path $PkgPath)) { Err "找不到 profile：$ProfileDir"; exit 1 }

Show-Dashboard

# 前置检查：缺依赖时只提示，不阻断（查看类功能仍可用）
if (-not (Get-Command pnpm -ErrorAction SilentlyContinue)) {
    Write-Host ""
    Err "未找到 pnpm —— 安装/更新/卸载会失败。"
    Dim "安装方法：npm install -g pnpm"
}
if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
    Write-Host ""
    Err "未找到 node —— 插件目录索引无法生成。"
    Dim "安装方法：https://nodejs.org/ 下载 LTS 版"
}

# 启动时自动检查更新；6 小时内检查过则跳过，避免每次开都等 20 秒
$needCheck = $true
$cached = Get-OutdatedCache
if ($cached) {
    try {
        $needCheck = (((Get-Date) - [datetime]::Parse($cached.at)).TotalHours -gt 6)
    }
    catch { $needCheck = $true }
}
if ($needCheck) {
    Write-Host "  正在检查插件更新（约 10-20 秒，6 小时内只检查一次）..." -ForegroundColor DarkGray
    [void](Invoke-CheckUpdates)
    Show-Dashboard
}

while ($true) {
    $line = Read-Host "  >"
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    $line = $line.Trim()
    # 容错：i<关键词> 这种照抄文档的写法，自动拆成 "i 关键词"
    $line = $line -replace '^([a-zA-Z]+)<', '$1 <'
    $parts = @($line -split '\s+', 2)
    $cmd = $parts[0].ToLower()
    $arg = ""
    if ($parts.Count -gt 1) { $arg = $parts[1].Trim() }

    switch ($cmd) {
        "help" { Show-Help }
        "?"    { Show-Help }
        "h"    { Show-Help }

        "ls"   { Show-Dashboard }
        "list" { Show-Dashboard }

        "check"   { [void](Invoke-CheckUpdates) }
        "refresh" { [void](Update-Catalog $CacheDir $true) }
        "start"   { Start-Dsh }
        "run"     { Start-Dsh }

        "i"       { Do-SearchInstall $arg }
        "install" { Do-SearchInstall $arg }
        "add"     { Do-SearchInstall $arg }

        "u"      { Handle-Update $arg }
        "update" { Handle-Update $arg }
        "up"     { Handle-Update $arg }

        "rm"        { Handle-Remove $arg }
        "remove"    { Handle-Remove $arg }
        "uninstall" { Handle-Remove $arg }

        "info" {
            if ($arg -match '^\d+$') { Show-PluginDetail ([int]$arg) }
            else { Err "用法：info 序号（也可以直接输序号）" }
        }

        "q"    { Clear-Host; return }
        "quit" { Clear-Host; return }
        "exit" { Clear-Host; return }

        default {
            $idx = Resolve-PluginIndex $cmd
            if ($idx -gt 0) { Show-PluginDetail $idx }
            elseif ($idx -eq -1) {
                if ($cmd -match '[<>]') {
                    Err "未知命令：$cmd"
                    Dim "尖括号只是文档里的占位写法，实际输入不要写。例如：i sidebar"
                }
                else { Err "未知命令或插件：$cmd（输入 help 查看）" }
            }
        }
    }
}
