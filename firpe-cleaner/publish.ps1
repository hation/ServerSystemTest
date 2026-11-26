# ============================================================================
# publish.ps1 — 发布 FirpeCleaner 为 self-contained 目录版（WinPE/FirPE 离线运行）
# 用法：powershell -NoProfile -ExecutionPolicy Bypass -File publish.ps1
# 产物：firpe-cleaner/dist/FirpeCleaner/（exe + 全部 DLL 平铺，零 .NET 依赖）
# 说明：目录发布 native 库直接加载零解压；WinPE 复制整个目录到 U 盘即可。
#       （单文件压缩/自解压会在 WinPE X: 临时盘解压失败致静默退出，已禁用）
# ============================================================================
$ErrorActionPreference = 'Stop'

# 项目根：本文件所在目录（publish.ps1 位于 firpe-cleaner/ 根）
$Root = $PSScriptRoot
$Project = Join-Path $Root 'src\FirpeCleaner\FirpeCleaner.csproj'
$Dist = Join-Path $Root 'dist'

if (-not (Test-Path -LiteralPath $Project)) {
    throw "项目文件缺失: $Project"
}

# 定位 dotnet：优先 PATH，回退标准安装路径
$dotnetCmd = Get-Command dotnet -ErrorAction SilentlyContinue
if ($dotnetCmd) {
    $dotnet = $dotnetCmd.Source
} else {
    $candidate = 'C:\Program Files\dotnet\dotnet.exe'
    if (-not (Test-Path -LiteralPath $candidate)) {
        throw '未找到 dotnet：PATH 与 C:\Program Files\dotnet\dotnet.exe 均不可用'
    }
    $dotnet = $candidate
}
Write-Host "==> dotnet: $dotnet"

# 发布：win-x64 自包含目录版（非单文件，native 库平铺直接加载零解压）
$OutDir = Join-Path $Dist 'FirpeCleaner'
& $dotnet publish $Project -r win-x64 --self-contained true -p:PublishSingleFile=false -o $OutDir
if ($LASTEXITCODE -ne 0) {
    throw "dotnet publish 失败（exit=$LASTEXITCODE）"
}

# 产物校验：exe + 关键 DLL 存在（目录版而非单文件）
$exe = Join-Path $OutDir 'FirpeCleaner.exe'
if (-not (Test-Path -LiteralPath $exe)) {
    throw "发布产物缺失: $exe"
}
$coreDll = Join-Path $OutDir 'FirpeCleaner.Core.dll'
if (-not (Test-Path -LiteralPath $coreDll)) {
    Write-Warning "缺少 FirpeCleaner.Core.dll，疑似误发布为单文件，请检查参数"
}
$sizeMB = [math]::Round((Get-Item -LiteralPath $exe).Length / 1MB, 1)
$dllCount = (Get-ChildItem -LiteralPath $OutDir -Filter '*.dll' -File | Measure-Object).Count
Write-Host ("==> 发布完成: {0}（exe {1} MB，目录共 {2} 个 DLL）" -f $OutDir, $sizeMB, $dllCount)
