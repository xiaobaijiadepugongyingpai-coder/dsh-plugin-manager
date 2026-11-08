# 插件目录：下载、缓存、搜索
# 数据源：https://awesome-dsh-plugin.com/plugins.json（DSH 插件市场使用的同一份）

$script:CatalogUrl     = "https://awesome-dsh-plugin.com/plugins.json"
$script:CatalogTtlDays = 7
$script:IndexFormat    = 2   # 2 = 增加 url 列；格式变化时自动重建索引

function Get-CatalogPaths($cacheDir) {
    return @{
        Raw   = Join-Path $cacheDir "catalog.json"
        Index = Join-Path $cacheDir "catalog-index-v$($script:IndexFormat).tsv"
        Meta  = Join-Path $cacheDir "catalog.meta"
    }
}

function Get-CatalogAgeDays($metaPath) {
    if (-not (Test-Path $metaPath)) { return -1 }
    try {
        $meta = Get-Content $metaPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $at = [datetime]::Parse($meta.at)
        return [math]::Round(((Get-Date) - $at).TotalDays, 1)
    }
    catch { return -1 }
}

function Build-CatalogIndex($cacheDir, $rawPath) {
    $p = Get-CatalogPaths $cacheDir
    $builder = Join-Path $PSScriptRoot "build-index.js"
    $count = & node $builder $rawPath $p.Index 2>&1
    if ($LASTEXITCODE -ne 0) { return -1 }
    $meta = @{ at = (Get-Date).ToString("o"); count = [int]$count; url = $script:CatalogUrl; format = $script:IndexFormat }
    $meta | ConvertTo-Json | Set-Content $p.Meta -Encoding UTF8
    return [int]$count
}

function Update-Catalog($cacheDir, $force) {
    $p = Get-CatalogPaths $cacheDir
    New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null

    $age = Get-CatalogAgeDays $p.Meta
    if (-not $force -and $age -ge 0 -and $age -lt $script:CatalogTtlDays -and (Test-Path $p.Index)) {
        return $true
    }

    # 索引缺失但原始数据还在（例如索引格式升级）→ 本地重建，不必重新下载
    if (-not $force -and (Test-Path $p.Raw)) {
        Write-Host "  正在重建索引..." -ForegroundColor DarkGray
        $n = Build-CatalogIndex $cacheDir $p.Raw
        if ($n -ge 0) {
            Write-Host "  索引已重建：$n 个可安装插件" -ForegroundColor Green
            return $true
        }
    }

    Write-Host ""
    Write-Host "  首次使用需要下载插件目录（约 11 MB，视网络 30-90 秒）。" -ForegroundColor Yellow
    Write-Host "  之后会缓存 $($script:CatalogTtlDays) 天，不用每次下载。" -ForegroundColor DarkGray
    Write-Host ""

    $tmp = "$($p.Raw).download"
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue

    # 用 curl 下载，能显示进度条；不依赖 PowerShell 的慢速进度实现
    $curl = Join-Path $env:SystemRoot "System32\curl.exe"
    if (-not (Test-Path $curl)) { $curl = "curl.exe" }

    & $curl --noproxy "*" -L --compressed --progress-bar -o $tmp $script:CatalogUrl 2>&1 | Out-Host
    $code = $LASTEXITCODE
    Write-Host ""

    if ($code -ne 0 -or -not (Test-Path $tmp) -or (Get-Item $tmp).Length -lt 100000) {
        Write-Host "  下载失败（curl exit=$code）。可以稍后重试，或直接用完整包名安装。" -ForegroundColor Red
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        return $false
    }

    Write-Host "  正在建立索引..." -ForegroundColor DarkGray
    $count = Build-CatalogIndex $cacheDir $tmp
    if ($count -lt 0) {
        Write-Host "  索引建立失败，请确认已安装 Node.js" -ForegroundColor Red
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        return $false
    }

    Move-Item $tmp $p.Raw -Force
    Write-Host "  目录已更新：$count 个可安装插件" -ForegroundColor Green
    return $true
}

function Get-CatalogLines($cacheDir) {
    $p = Get-CatalogPaths $cacheDir
    if (-not (Test-Path $p.Index)) { return @() }
    return @(Get-Content $p.Index -Encoding UTF8 | Where-Object { $_ -ne "" })
}

function Get-CatalogMeta($cacheDir) {
    $p = Get-CatalogPaths $cacheDir
    if (-not (Test-Path $p.Meta)) { return $null }
    try { return Get-Content $p.Meta -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $null }
}

function Search-Catalog($lines, $keyword, $limit) {
    $terms = @($keyword.ToLower().Split(" ") | Where-Object { $_ -ne "" })
    if ($terms.Count -eq 0) { return @() }

    $hits = New-Object System.Collections.ArrayList
    foreach ($line in $lines) {
        $low = $line.ToLower()
        $ok = $true
        foreach ($t in $terms) {
            if ($low.IndexOf($t) -lt 0) { $ok = $false; break }
        }
        if (-not $ok) { continue }

        $f = $line.Split("`t")
        $npm = $f[0]
        # 打分：包名命中优先于描述命中
        $score = 0
        foreach ($t in $terms) {
            if ($npm.ToLower().IndexOf($t) -ge 0) { $score += 10 }
            elseif ($f[2] -and $f[2].ToLower().IndexOf($t) -ge 0) { $score += 5 }
            else { $score += 1 }
        }
        [void]$hits.Add([pscustomobject]@{
            Score = $score
            Npm   = $npm
            Ver   = $f[1]
            Name  = $f[2]
            Cat   = $f[3]
            Desc  = $f[4]
            Url   = $(if ($f.Count -gt 6) { $f[6] } else { "" })
        })
    }

    $sorted = @($hits | Sort-Object -Property @{ Expression = "Score"; Descending = $true }, @{ Expression = "Npm"; Descending = $false })
    if ($limit -gt 0 -and $sorted.Count -gt $limit) { return @($sorted[0..($limit - 1)]) }
    return $sorted
}
