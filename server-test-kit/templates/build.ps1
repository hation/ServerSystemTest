# ============================================================================
# build.ps1 — 通用构建骨架（VERSION 单源，PowerShell 5.1 兼容）
# 用法：powershell -NoProfile -ExecutionPolicy Bypass -File build.ps1 [-Zip] [-SkipVerify]
# 流程：读根目录 VERSION → 重建 dist\<project>-<version>\ → 拷贝 bin/conf/tests/docs →
#       注入版本（lib_common.ps1 版本行 / README 版本行）→ 产物校验（关键文件存在性 + VERSION 一致）
#       → 打印产物路径 →（-Zip）先删旧包再建新包，打包后校验 zip 内关键文件 hash 与 dist 一致
# 幂等：重复构建（版本不变）产物一致；-Zip 每次覆盖旧包，失败不残留旧包。
# 定位：本文件放 scripts\（或 bin\）子目录中，自动以父目录为项目根（同 memory-tests）。
# ============================================================================
[CmdletBinding()]
param(
    [switch]$Zip,        # 构建后压缩为 <project>-<version>.zip（先删旧包再建新包）
    [switch]$SkipVerify  # 跳过产物校验（调试用，不推荐交付）
)

$ErrorActionPreference = 'Stop'

# 项目根：本文件所在目录的父目录（build.ps1 放项目根或 scripts\ 下均适用）
$Repo = Split-Path -Parent $PSScriptRoot
# 项目名：与 lib_common.ps1 的 $script:ProjectName 保持一致（占位，可改）
$ProjectName = 'server-tests'

# ---------- ① 版本（单一来源） ----------
$VERSION_FILE = Join-Path $Repo 'VERSION'
if (-not (Test-Path -LiteralPath $VERSION_FILE)) {
    throw "VERSION 文件缺失: $VERSION_FILE（VERSION 为唯一版本来源，先创建）"
}
$ver = (Get-Content -LiteralPath $VERSION_FILE -Raw).Trim()

# ---------- ② 重建 dist\<project>-<version>\ 并拷贝 ----------
$distRoot = Join-Path $Repo 'dist'
$kitDir = Join-Path $distRoot ("{0}-{1}" -f $ProjectName, $ver)
if (Test-Path -LiteralPath $kitDir) { Remove-Item -LiteralPath $kitDir -Recurse -Force }
New-Item -ItemType Directory -Path $kitDir -Force | Out-Null
foreach ($d in @('bin', 'conf', 'tests', 'docs')) {
    $src = Join-Path $Repo $d
    $dst = Join-Path $kitDir $d
    if (-not (Test-Path -LiteralPath $src)) {
        Write-Warning "源目录缺失（骨架阶段允许暂缺，跳过）: $src"
        continue
    }
    New-Item -ItemType Directory -Path $dst -Force | Out-Null
    Get-ChildItem -LiteralPath $src -Force | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination $dst -Recurse -Force
    }
}
# 根目录 README.md 随包携带（若有）
if (Test-Path -LiteralPath (Join-Path $Repo 'README.md')) {
    Copy-Item -LiteralPath (Join-Path $Repo 'README.md') -Destination $kitDir -Force
}

# ---------- ③ 注入版本 ----------
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
# dist\VERSION：单源随包携带
[System.IO.File]::WriteAllText((Join-Path $kitDir 'VERSION'), $ver, $utf8NoBom)

# lib_common.ps1：把"工具版本：dev"占位行替换为 "工具版本：<ver>"（幂等：固定行模式）
$libPath = Join-Path $kitDir 'bin\lib_common.ps1'
if (Test-Path -LiteralPath $libPath) {
    $raw = [System.IO.File]::ReadAllText($libPath, $utf8NoBom)
    $new = [regex]::Replace($raw, '(?m)^# 工具版本：.*$', ("# 工具版本：{0}（由 build.ps1 从 VERSION 注入）" -f $ver))
    [System.IO.File]::WriteAllText($libPath, $new, $utf8NoBom)
}

# README.md：幂等注入版本行（先删所有旧"工具版本："行再插入新行，避免叠加；写回带 BOM 防 PS5 中文乱码）
$readmePath = Join-Path $kitDir 'README.md'
if (Test-Path -LiteralPath $readmePath) {
    $raw = [System.IO.File]::ReadAllText($readmePath, $utf8NoBom).TrimEnd("`r", "`n")
    $lines = $raw -split "`r?`n"
    $filtered = @($lines | Where-Object { $_ -notmatch '^>\s*工具版本：' })
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("> 工具版本：$ver")
    foreach ($l in $filtered) { [void]$sb.AppendLine($l) }
    [System.IO.File]::WriteAllText($readmePath, $sb.ToString(), (New-Object System.Text.UTF8Encoding($true)))
}

# ---------- ④ 产物校验（-SkipVerify 跳过） ----------
if (-not $SkipVerify) {
    $required = @(
        (Join-Path $kitDir 'VERSION'),
        (Join-Path $kitDir 'bin\lib_common.ps1'),
        (Join-Path $kitDir 'conf\app.conf')
    )
    $missing = @($required | Where-Object { -not (Test-Path -LiteralPath $_) })
    if ($missing.Count -gt 0) {
        throw "产物校验失败，关键文件缺失: $($missing -join ', ')"
    }
    # VERSION 一致：dist 内 VERSION 必须与源 VERSION 相同
    $kitVer = (Get-Content -LiteralPath (Join-Path $kitDir 'VERSION') -Raw).Trim()
    if ($kitVer -ne $ver) {
        throw "产物校验失败：dist VERSION($kitVer) 与源 VERSION($ver) 不一致"
    }
    # 版本注入校验：lib_common.ps1 占位行必须已被替换
    $libText = [System.IO.File]::ReadAllText((Join-Path $kitDir 'bin\lib_common.ps1'), $utf8NoBom)
    if ($libText -match '(?m)^# 工具版本：dev') {
        throw "产物校验失败：lib_common.ps1 版本行未注入（仍为 dev）"
    }
    Write-Host "==> 产物校验通过（关键文件存在 + VERSION 一致 + 版本已注入）"
}

Write-Host "==> 构建完成: $kitDir（版本 $ver）"

# ---------- ⑤ -Zip：先删旧包 → 打包 → 校验 zip 内关键文件 hash 与 dist 一致 ----------
if ($Zip) {
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zipPath = Join-Path $Repo ("{0}-{1}.zip" -f $ProjectName, $ver)
    $zipTmp = "$zipPath.tmp"
    # 打包纪律：先删旧包再建新包（失败也不残留旧包，杜绝旧版被误用）
    foreach ($f in @($zipPath, $zipTmp)) {
        if (Test-Path -LiteralPath $f) {
            Set-ItemProperty -LiteralPath $f -Name IsReadOnly -Value $false -ErrorAction SilentlyContinue
        }
    }
    Remove-Item -LiteralPath $zipTmp -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue

    # 递归打包（保留空目录条目，参考 disk-tests make_deploy_zip.ps1）
    $script:zipCount = 0
    function Add-ZipDir([string]$base, [string]$rel, $archive) {
        $full = if ($rel) { Join-Path $base $rel } else { $base }
        foreach ($item in Get-ChildItem -LiteralPath $full -Force) {
            $childRel = if ($rel) { "$rel/$($item.Name)" } else { $item.Name }
            if ($item.PSIsContainer) {
                [void]$archive.CreateEntry("$childRel/")
                Add-ZipDir $base $childRel $archive
            } else {
                $entry = $archive.CreateEntry($childRel)
                $s = $entry.Open()
                $in = [System.IO.File]::OpenRead($item.FullName)
                $in.CopyTo($s)
                $in.Dispose(); $s.Dispose()
                $script:zipCount++
            }
        }
    }
    $fs = [System.IO.Compression.ZipFile]::Open($zipTmp, 'Create')
    Add-ZipDir $kitDir '' $fs
    $fs.Dispose()
    Move-Item -LiteralPath $zipTmp -Destination $zipPath -Force

    # zip 校验：关键文件在包内且 hash 与 dist 一致
    # 注意：$zipArc 变量名避开 param 的 -Zip switch（PS 变量名大小写不敏感，$zip 与 $Zip 同名会冲突）
    if (-not $SkipVerify) {
        $zipArc = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
        try {
            foreach ($rel in @('VERSION', 'bin/lib_common.ps1', 'conf/app.conf')) {
                $entry = $zipArc.GetEntry($rel)
                if (-not $entry) { throw "zip 内缺少关键文件: $rel" }
                $stream = $entry.Open()
                try {
                    $sha = [System.Security.Cryptography.SHA256]::Create()
                    $zipHash = ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-', '').ToLowerInvariant()
                    $distHash = (Get-FileHash -LiteralPath (Join-Path $kitDir ($rel -replace '/', '\')) -Algorithm SHA256).Hash.ToLowerInvariant()
                    if ($zipHash -ne $distHash) { throw "zip 内 $rel hash 与 dist 不一致" }
                } finally { $stream.Dispose() }
            }
        } finally { $zipArc.Dispose() }
        Write-Host "==> zip 校验通过：关键文件 hash 与 dist 一致"
    }
    $info = Get-Item $zipPath
    Write-Host ("==> 交付包: {0}（{1} MB, {2} 文件）" -f $zipPath, [math]::Round($info.Length / 1MB, 1), $script:zipCount)
}
