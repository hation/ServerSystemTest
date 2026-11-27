# Task 9 brief — FirPE 无法启动修复（去 requireAdministrator + 非单文件压缩发布）

## 背景

用户 FirPE 里双击 FirpeCleaner.exe **完全无反应**；CMD 手动运行也无输出（进程静默退出）。
根因分析（联网证据）：
1. **嫌疑 1（最高）：单文件 self-extract 在 WinPE 解压失败**——csproj 用
   `IncludeNativeLibrariesForSelfExtract=true` + `EnableCompressionInSingleFile=true`，
   启动时把内嵌 native DLL 解压到 `%TEMP%`（WinPE 在 X: 内存盘，空间不足/不可写）
   → 解压失败静默退出。微软文档：单文件压缩有启动开销，WPF self-contained 单文件有
   已知启动崩溃问题。
2. **嫌疑 2：`requireAdministrator` 在 WinPE 提权静默失败**——WinPE 无完整 UAC 机制。

**修复：① 去掉 requireAdministrator；② 改非单文件压缩发布（native DLL 直接放目录，
WinPE 启动时不再运行时解压）**。FirPE 以 SYSTEM/管理员运行，去掉提权要求无碍；发布目录
形态 native 库平铺，无解压步骤。

## 任务（精确，基于 HEAD=d9d02bc）

### 1. `firpe-cleaner/src/FirpeCleaner/app.manifest`：去掉 requireAdministrator
- `<requestedExecutionLevel level="requireAdministrator" uiAccess="false" />`
  → `<requestedExecutionLevel level="asInvoker" uiAccess="false" />`
  （FirPE/WinPE 以 SYSTEM 运行，本就有最高权限；asInvoker 避免 UAC 提权路径）
- 保留 dpiAwareness=PerMonitorV2

### 2. `firpe-cleaner/src/FirpeCleaner/FirpeCleaner.csproj`：改发布配置
- 去掉 `EnableCompressionInSingleFile=true`
- 去掉 `IncludeNativeLibrariesForSelfExtract=true`
- 保留 `PublishSingleFile=true` + `SelfContained=true`（单文件但**不压缩、不内嵌
  native 需解压**——单文件形态 native 库会随 exe 自解压到临时目录，为避免 WinPE
  解压问题，**直接改回非单文件目录发布**更稳：`PublishSingleFile=false`，输出目录
  含 exe + 全部 DLL，native 库平铺直接加载，零解压）
- 决策：**`PublishSingleFile=false`**（目录发布，最稳；WinPE 复制整个目录到 U 盘即可）
- 保留 `RuntimeIdentifier=win-x64`、`SelfContained=true`、`DebugType=none`

### 3. `firpe-cleaner/publish.ps1`：同步（去掉单文件参数，输出目录版）
- 输出 `dist/FirpeCleaner/`（目录，含 exe + DLL）

### 4. README 更新：集成说明改为复制**整个 dist 目录**到 FirPE U 盘 `FirPE\Desktop\`
（不是单个 exe）

### 5. 验证
- `dotnet build` 0 warning 0 error
- `dotnet publish` 输出目录版（dist/FirpeCleaner/ 含 exe+DLL）
- 本机跑 exe 冒烟：窗口出现不崩（去掉提权后本机非提权也能直接跑）
- 不真 clean

### 6. Commit
`fix(firpe-cleaner): FirPE 无法启动修复——去 requireAdministrator + 改非单文件目录发布（WinPE 无 UAC 提权路径、单文件 native 解压到 X: 临时盘失败致静默退出）`

## 环境

- dotnet 8 SDK（PATH 或 C:\Program Files\dotnet\dotnet.exe）；只改 firpe-cleaner/

## 禁止

- 不改 Core/GUI 逻辑（纯发布配置调整）；不真 clean；不 push

## 报告

写 `firpe-cleaner/task9-report.md`：改动说明、发布输出（dist 目录结构）、本机启动验证、commit hash。
返回：状态（DONE/BLOCKED）、commit hash、一行摘要、concerns。