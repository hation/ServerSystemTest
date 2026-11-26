# ============================================================================
# publish.ps1 — 发布 FirpeCleaner 为 self-contained 单文件 exe（WinPE/FirPE 离线运行）
# 用法：powershell -NoProfile -ExecutionPolicy Bypass -File publish.ps1
# 产物：firpe-cleaner/dist/FirpeCleaner.exe（单文件，约 60-70MB，零 .NET 依赖）
# 说明：IncludeNativeLibrariesForSelfExtract 已内置于 csproj（默认组），
#       WinPE 下 WPF/原生库自解压可运行；本脚本按 brief 显式传关键发布参数。
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

# 发布：win-x64 自包含单文件（含压缩）
& $dotnet publish $Project -r win-x64 --self-contained true -p:PublishSingleFile=true -p:EnableCompressionInSingleFile=true -o $Dist
if ($LASTEXITCODE -ne 0) {
    throw "dotnet publish 失败（exit=$LASTEXITCODE）"
}

# 产物校验：单文件存在 + 大小合理（self-contained 单文件应明显大于 10MB）
$exe = Join-Path $Dist 'FirpeCleaner.exe'
if (-not (Test-Path -LiteralPath $exe)) {
    throw "发布产物缺失: $exe"
}
$sizeMB = [math]::Round((Get-Item -LiteralPath $exe).Length / 1MB, 1)
if ($sizeMB -lt 10) {
    Write-Warning "产物过小（${sizeMB}MB），疑似未打包为 self-contained 单文件，请检查参数"
}
Write-Host ("==> 发布完成: {0}（{1} MB）" -f $exe, $sizeMB)
