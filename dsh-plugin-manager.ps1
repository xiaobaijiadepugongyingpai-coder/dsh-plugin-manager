#Requires -Version 5.1
<#
    DSH 插件管理器（离线）
    功能：安装 / 查看可更新 / 更新指定 / 一键更新全部
    说明：所有写操作都要求 DSH 已完全退出，并自动备份配置。
#>

$ErrorActionPreference = "Stop"
$profileDir = Join-Path $env:USERPROFILE ".dsh\profiles\desktop"
$pkgPath    = Join-Path $profileDir "package.json"
$env:ELECTRON_MIRROR     = "https://npmmirror.com/mirrors/electron/"
$env:ELECTRON_CUSTOM_DIR = "{{ version }}"

# ---------------- 工具函数 ----------------

function Step($m) { Write-Host "==> $m" -ForegroundColor Cyan }
function Ok($m)   { Write-Host $m -ForegroundColor Green }
function Warn($m) { Write-Host $m -ForegroundColor Yellow }
function Err($m)  { Write-Host $m -ForegroundColor Red }

function Test-DshClosed {
    $p = Get-Process -Name "DeepSeek Harness" -ErrorAction SilentlyContinue
    if ($p) {
        Err "检测到 dsh 正在运行（$($p.Count) 个进程）。"
        Warn "请在托盘退出 DSH，并在任务管理器确认没有 DeepSeek Harness 进程后重试。"
        return $false
    }
    return $true
}

function Backup-Profile {
    $stamp  = Get-Date -Format "yyyyMMdd-HHmmss"
    $dir    = Join-Path $profileDir "_install-backup-$stamp"
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    foreach ($f in @("package.json", "pnpm-lock.yaml", "cordis.patch.yml")) {
        $src = Join-Path $profileDir $f
        if (Test-Path $src) { Copy-Item $src $dir -Force }
    }
    Step "已备份到 $dir"
    return $dir
}

function Get-Registry {
    try {
        $r = (& npm config get registry 2>$null | Select-Object -First 1)
        if ($r) { return $r.Trim().TrimEnd('/') }
    } catch {}
    return "https://registry.npmjs.org"
}

function Get-LatestVersion($name, $registry) {
    $enc = $name.Replace('/', '%2F')
    try {
        $r = Invoke-RestMethod -Uri "$registry/$enc/latest" -TimeoutSec 15 -UseBasicParsing
        if ($r.version) { return $r.version }
    } catch {}
    try {
        $v = (& npm view $name version 2>$null | Select-Object -First 1)
        if ($v) { return $v.Trim() }
    } catch {}
    return $null
}

function Compare-Semver($a, $b) {
    # 返回 1 表示 a>b，-1 表示 a<b，0 相等
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
    if ($hasA -and -not $hasB) { return -1 }   # 预发布版 < 正式版
    if (-not $hasA -and $hasB) { return 1 }
    if ($hasA -and $hasB) {
        $r = [string]::CompareOrdinal($pa[1], $pb[1])
        if ($r -gt 0) { return 1 }
        if ($r -lt 0) { return -1 }
    }
    return 0
}

function Get-OutdatedList {
    $json = Get-Content $pkgPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $registry = Get-Registry
    $list = @()
    $i = 0
    $total = ($json.dependencies.PSObject.Properties | Measure-Object).Count
    Write-Host "  检查中（共 $total 个，约 10-20 秒）：" -NoNewline -ForegroundColor DarkGray
    foreach ($dep in $json.dependencies.PSObject.Properties) {
        $i++
        $latest = Get-LatestVersion $dep.Name $registry
        if ($latest -and (Compare-Semver $latest $dep.Value) -gt 0) {
            $list += [pscustomobject]@{ Name = $dep.Name; Current = $dep.Value; Latest = $latest }
            Write-Host "." -NoNewline -ForegroundColor Green
        }
        else {
            Write-Host "." -NoNewline -ForegroundColor DarkGray
        }
    }
    Write-Host ""
    return $list
}

function Invoke-Pnpm($argsList) {
    # 不捕获输出：让 pnpm 直接在控制台绘制进度条（下载进度、包数统计）。
    # 用 Out-Host 把输出送到控制台而不进入函数返回值——否则返回值会被输出污染，
    # 导致 $code 变成数组，出现"明明成功却报失败"的误判。
    $cmdLine = "pnpm " + ($argsList -join ' ') + " 2>&1"
    Push-Location $profileDir
    try {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        cmd /c $cmdLine | Out-Host
        $code = $LASTEXITCODE
        $sw.Stop()
    }
    finally { Pop-Location }
    Write-Host ("  耗时 {0:N1} 秒" -f $sw.Elapsed.TotalSeconds) -ForegroundColor DarkGray
    return $code
}

function Repair-Electron {
    $e = Join-Path $profileDir "node_modules\electron"
    $exe = Join-Path $e "dist\electron.exe"
    if ((Test-Path $e) -and (-not (Test-Path $exe))) {
        Warn "electron 二进制缺失，正在用国内镜像修复（约 19 秒）..."
        Push-Location $e
        try { & node install.js } finally { Pop-Location }
        if (Test-Path $exe) { Ok "electron 已修复" } else { Err "electron 修复失败，请参考教程第六节" }
    }
}

function Add-ToBundles($name) {
    $json = Get-Content $pkgPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $bundles = @($json.dsh.profile.bundles)
    if ($bundles -contains $name) { Step "bundles 中已存在，跳过"; return }
    $list = New-Object System.Collections.ArrayList
    foreach ($b in $bundles) { [void]$list.Add($b) }
    $idx = $list.IndexOf("@linxin666/dsh-web-all")
    if ($idx -ge 0) { $list.Insert($idx, $name) } else { [void]$list.Add($name) }
    $json.dsh.profile.bundles = @($list)
    # 注意：不能用 Set-Content -Encoding UTF8（PS 5.1 会写入 BOM，严格 JSON 解析器会报错）
    $out = $json | ConvertTo-Json -Depth 10
    [System.IO.File]::WriteAllText($pkgPath, $out, (New-Object System.Text.UTF8Encoding($false)))
    Step "已写入 bundles（当前 $($list.Count) 项）"
}

# ---------------- 功能 ----------------

function Do-Install {
    $name = Read-Host "请输入插件包名（例如 dsh-computer-use-win）"
    if ([string]::IsNullOrWhiteSpace($name)) { return }
    $name = $name.Trim()
    $ver = Read-Host "指定版本（直接回车=最新）"
    $spec = $name
    if (-not [string]::IsNullOrWhiteSpace($ver)) { $spec = "$name@$($ver.Trim())" }

    if (-not (Test-DshClosed)) { return }
    [void](Backup-Profile)
    Step "安装 $spec （可能需要 10-60 秒）"
    $code = Invoke-Pnpm @("add", $spec, "--save-exact")
    if ($code -ne 0) { Err "安装失败（exit=$code），package.json 已回滚。"; return }
    Add-ToBundles $name
    Repair-Electron
    Ok "安装完成，可以启动 DSH 了。"
}

function Do-Check {
    Step "读取已安装插件并检查最新版本..."
    $list = Get-OutdatedList
    if ($list.Count -eq 0) { Ok "所有插件都是最新版。"; return @() }
    Write-Host ""
    Write-Host ("{0,-42} {1,-14} {2,-14}" -f "插件", "当前版本", "最新版本") -ForegroundColor White
    Write-Host ("-" * 72) -ForegroundColor DarkGray
    foreach ($x in $list) {
        Write-Host ("{0,-42} {1,-14} " -f $x.Name, $x.Current) -NoNewline
        Write-Host $x.Latest -ForegroundColor Green
    }
    Write-Host ""
    return $list
}

function Do-UpdateOne {
    $list = Do-Check
    if (-not $list -or $list.Count -eq 0) { return }
    Write-Host "可更新的插件："
    for ($i = 0; $i -lt $list.Count; $i++) {
        Write-Host ("  [{0}] {1}  {2} -> {3}" -f ($i + 1), $list[$i].Name, $list[$i].Current, $list[$i].Latest)
    }
    $sel = Read-Host "输入序号（回车取消）"
    if ([string]::IsNullOrWhiteSpace($sel)) { return }
    $idx = 0
    if (-not [int]::TryParse($sel.Trim(), [ref]$idx)) { Err "无效序号"; return }
    if ($idx -lt 1 -or $idx -gt $list.Count) { Err "序号超出范围"; return }

    $target = $list[$idx - 1]
    if (-not (Test-DshClosed)) { return }
    [void](Backup-Profile)
    Step "更新 $($target.Name)  $($target.Current) -> $($target.Latest)"
    $code = Invoke-Pnpm @("add", "$($target.Name)@$($target.Latest)", "--save-exact")
    if ($code -ne 0) { Err "更新失败（exit=$code）"; return }
    Repair-Electron
    Ok "更新完成。"
}

function Do-UpdateAll {
    $list = Do-Check
    if (-not $list -or $list.Count -eq 0) { return }
    Warn "即将更新上面 $($list.Count) 个插件。"
    Warn "注意：更新后如果某个插件与当前 DSH 版本不兼容，可能导致启动异常。"
    Warn "出问题可从备份目录还原 package.json / pnpm-lock.yaml。"
    $ans = Read-Host "确认继续？输入 y 回车执行，其它取消"
    if ($ans -ne "y" -and $ans -ne "Y") { return }
    if (-not (Test-DshClosed)) { return }
    [void](Backup-Profile)

    Step "执行 pnpm up --latest（一次性更新，比逐个更新快很多）"
    $code = Invoke-Pnpm @("up", "--latest")
    if ($code -ne 0) { Err "更新失败（exit=$code）"; return }
    Repair-Electron
    Ok "更新完成，可以启动 DSH 了。"
}

function Get-PluginDataPaths($name) {
    # 只处理 ~/.dsh 下与插件同名的一级目录，以及少量已知映射。
    # 绝不触碰 profiles / storages / skills 等核心目录。
    $dshHome = Join-Path $env:USERPROFILE ".dsh"
    $base = $name.Split('/')[-1]
    $protected = @('profiles','storages','skills','logs','dsh-session-archive',
                   'dsh-usage','dsh-agents','task-board','bin','cache','tools','node_modules')

    $paths = @()
    if ($protected -notcontains $base) {
        $p = Join-Path $dshHome $base
        if (Test-Path $p) { $paths += $p }
    }

    $extra = @{
        'dsh-pet' = @('pet.json', 'pets')
    }
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
    if ($paths.Count -eq 0) { Step "未发现该插件的独立数据目录。"; return }

    Write-Host ""
    Write-Host "该插件在 ~/.dsh 下还有以下数据：" -ForegroundColor Yellow
    $totalSize = 0
    foreach ($p in $paths) {
        $sum = (Get-ChildItem $p -Recurse -File -Force -ErrorAction SilentlyContinue |
                Measure-Object -Property Length -Sum).Sum
        if (-not $sum) { $sum = 0 }
        $totalSize += $sum
        Write-Host ("  {0}   ({1:N1} MB)" -f $p.Replace($env:USERPROFILE, '~'), ($sum / 1MB))
    }
    Write-Host ("  合计 {0:N1} MB" -f ($totalSize / 1MB)) -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  删除后：插件重装会回到初始状态（设置、账号、历史全部丢失）。" -ForegroundColor DarkYellow
    Write-Host "  保留：只移除代码，重装后配置还在。" -ForegroundColor DarkYellow
    Write-Host "  安全措施：不永久删除，而是移动到 ~/.dsh/_uninstall-trash-时间戳\ 可随时取回。" -ForegroundColor DarkGray

    $ans = Read-Host "是否删除这些数据？(y/N，直接回车=保留)"
    if ($ans -ne "y" -and $ans -ne "Y") { Step "已保留插件数据。"; return }

    Write-Host ""
    Warn "二次确认：请输入完整包名 $name"
    $confirm = Read-Host "请输入"
    if ($confirm -ne $name) {
        Warn "输入不匹配，已跳过数据删除（数据保留）。"
        return
    }

    $trash = Join-Path (Join-Path $env:USERPROFILE ".dsh") ("_uninstall-trash-" + (Get-Date -Format "yyyyMMdd-HHmmss"))
    New-Item -ItemType Directory -Force -Path $trash | Out-Null
    foreach ($p in $paths) {
        $leaf = Split-Path $p -Leaf
        try {
            Move-Item -LiteralPath $p -Destination (Join-Path $trash $leaf) -Force -ErrorAction Stop
            Step "已移入回收目录：$leaf"
        }
        catch { Err "移动失败：$leaf  ($($_.Exception.Message))" }
    }
    Ok "数据已移到：$trash"
    Warn "确认无问题后，可手动删除该回收目录以释放空间。"
}

function Do-Uninstall {
    $json = Get-Content $pkgPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $deps = @($json.dependencies.PSObject.Properties | ForEach-Object { $_.Name })
    if ($deps.Count -eq 0) { Warn "没有已安装的插件。"; return }
    $bundles = @($json.dsh.profile.bundles)

    Write-Host ""
    Write-Host "已安装的插件：" -ForegroundColor White
    Write-Host ("-" * 60) -ForegroundColor DarkGray
    for ($i = 0; $i -lt $deps.Count; $i++) {
        $mark = ""
        if ($bundles -notcontains $deps[$i]) { $mark = "   （未启用）" }
        Write-Host ("  [{0,2}] {1}{2}" -f ($i + 1), $deps[$i], $mark)
    }
    Write-Host ""

    $sel = Read-Host "输入要卸载的序号（回车取消）"
    if ([string]::IsNullOrWhiteSpace($sel)) { return }
    $idx = 0
    if (-not [int]::TryParse($sel.Trim(), [ref]$idx)) { Err "无效序号"; return }
    if ($idx -lt 1 -or $idx -gt $deps.Count) { Err "序号超出范围"; return }

    $name = $deps[$idx - 1]
    Warn "即将卸载：$name"
    Warn "该插件的本地数据（如 ~/.dsh 下的配置目录）不会自动删除。"
    $ans = Read-Host "确认卸载？输入 y 回车执行，其它取消"
    if ($ans -ne "y" -and $ans -ne "Y") { return }

    if (-not (Test-DshClosed)) { return }
    [void](Backup-Profile)

    Step "卸载 $name"
    $code = Invoke-Pnpm @("remove", $name)
    if ($code -ne 0) { Err "卸载失败（exit=$code）"; return }

    # 从 bundles 移除
    $json2 = Get-Content $pkgPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $remain = @($json2.dsh.profile.bundles | Where-Object { $_ -ne $name })
    $json2.dsh.profile.bundles = $remain
    $out2 = $json2 | ConvertTo-Json -Depth 10
    [System.IO.File]::WriteAllText($pkgPath, $out2, (New-Object System.Text.UTF8Encoding($false)))
    Step "已从 bundles 移除（剩 $($remain.Count) 项）"

    # 询问是否同时清理插件数据（默认保留，且只移动到回收目录）
    Remove-PluginData $name

    Repair-Electron
    Ok "卸载完成，可以启动 DSH 了。"
}

# ---------------- 主菜单 ----------------
if (-not (Test-Path $pkgPath)) { Err "找不到 profile：$profileDir"; exit 1 }

while ($true) {
    Write-Host ""
    Write-Host "==============================================" -ForegroundColor DarkCyan
    Write-Host "        DSH 插件管理器（离线）" -ForegroundColor White
    Write-Host "==============================================" -ForegroundColor DarkCyan
    Write-Host "  [1] 安装新插件"
    Write-Host "  [2] 查看可更新插件"
    Write-Host "  [3] 更新指定插件"
    Write-Host "  [4] 一键更新全部"
    Write-Host "  [5] 卸载插件"
    Write-Host "  [0] 退出"
    Write-Host ""
    $choice = Read-Host "请选择"

    switch ($choice.Trim()) {
        "1" { Do-Install }
        "2" { [void](Do-Check) }
        "3" { Do-UpdateOne }
        "4" { Do-UpdateAll }
        "5" { Do-Uninstall }
        "0" { return }
        default { Warn "无效选项，请输入 0-5" }
    }

    Write-Host ""
    Read-Host "按回车返回菜单" | Out-Null
}
