# FirpeCleaner Native - build script (TCC)
# 同时产出 x86 和 x64 两个版本：64 位 WinPE 默认无 Wow64，32 位 exe 可能跑不了，
# 所以两个版本都给，用户在 FirPE 里哪个能跑用哪个。
# TCC 缺 comctl32/advapi32 导入库，用 .def 文件作为链接输入生成。
$ErrorActionPreference = "Stop"

$root = "C:\Users\ganxin01\Documents\trae-work\ServerSystemTest\firpe-cleaner-native"
$tcc  = "C:\Users\ganxin01\Documents\trae-work\ServerSystemTest\native-tcc\tcc"
$src  = "$root\src"
$dist = "$root\dist"

New-Item -ItemType Directory -Force $dist | Out-Null

# 后续业务模块（磁盘枚举、diskpart 清理、驱动自愈）在此列表追加
$sources = @("$src\main.c", "$src\disks.c", "$src\diskpart.c", "$src\driver.c")
# comctl32/advapi32/gdi32 缺导入库，用 .def 文件作为链接输入生成
# （gdi32：AddFontResourceExA 加载自带字体用，v14 新增）
$defs    = @("$src\comctl32.def", "$src\advapi32.def", "$tcc\lib\gdi32.def")

Write-Output "== Build (x86) =="
& "$tcc\tcc.exe" -mwindows -o "$dist\FirpeCleaner32.exe" @sources @defs
if ($LASTEXITCODE -ne 0) { throw "x86 build failed" }

Write-Output "== Build (x64) =="
& "$tcc\x86_64-win32-tcc.exe" -mwindows -o "$dist\FirpeCleaner64.exe" @sources @defs
if ($LASTEXITCODE -ne 0) { throw "x64 build failed" }

# 不再嵌入 comctl32 v6 manifest：v6 视觉样式会让列头（SysHeader32）与
# MessageBox 使用主题字体，中文精简 WinPE 缺主题字体 → 界面乱码。
# 回退 comctl32 v5 系统默认字体 + 控件统一用内置位图字体 SYSTEM_FIXED_FONT
# （见 main.c CreateControls），绕过字体依赖。

Get-ChildItem "$dist\FirpeCleaner32.exe", "$dist\FirpeCleaner64.exe" | Select-Object Name, Length
Write-Output "== Build OK =="
