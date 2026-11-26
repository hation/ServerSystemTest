# Task 5 报告 — 发布 + FirPE 集成打包

- 状态：DONE
- Commit：`cd6649b`（`docs(firpe-cleaner): 发布脚本 + FirPE 集成 README`，一次 commit，message 用 brief 指定）

## 1. publish.ps1（发布脚本）

`firpe-cleaner/publish.ps1`（PowerShell 5 兼容，UTF-8 with BOM，与仓库 build.ps1 风格一致）：

- 定位 dotnet：优先 PATH，回退 `C:\Program Files\dotnet\dotnet.exe`（本机实际用后者）；
- 发布命令（brief 指定，原样）：

```powershell
dotnet publish src/FirpeCleaner/FirpeCleaner.csproj -r win-x64 --self-contained true -p:PublishSingleFile=true -p:EnableCompressionInSingleFile=true -o dist
```

- 产物校验：`dist/FirpeCleaner.exe` 存在 + 大小 >10MB（self-contained 单文件判据），失败即 throw；
- `IncludeNativeLibrariesForSelfExtract=true` 已内置于 csproj 默认属性组（WinPE 下 WPF/原生库自解压），无需重复传参。

## 2. 执行发布输出（2026-11-26 13:02）

```text
==> dotnet: C:\Program Files\dotnet\dotnet.exe
  正在确定要还原的项目…
  已还原 FirpeCleaner.csproj (用时 5.91 秒)
  已还原 FirpeCleaner.Core.csproj (用时 5.91 秒)
  FirpeCleaner.Core -> …\bin\Release\net8.0\FirpeCleaner.Core.dll
  FirpeCleaner -> …\bin\Release\net8.0-windows\win-x64\FirpeCleaner.dll
  FirpeCleaner -> …\dist\
==> 发布完成: …\firpe-cleaner\dist\FirpeCleaner.exe（68.8 MB）
```

## 3. 产物验证

- `dist/FirpeCleaner.exe`：**72,189,766 字节 ≈ 68.8 MB**（符合预期 ~60-70MB，self-contained 单文件）；
- dist 目录仅含该 exe（多余 `FirpeCleaner.Core.pdb` 已删除，保持单文件交付；dist/ 不入库）；
- `publish.ps1` 输出确认 `FirpeCleaner -> …\dist\`（单文件打包成功，无散落 dll）。

## 4. 本机启动验证（GUI 窗口出现，不崩）

环境：Windows 桌面会话（Session 1），非管理员 shell；Release manifest 为
`requireAdministrator`，UAC 启用（ConsentPromptBehaviorAdmin=5）。实际启动经 UAC 批准后以提权运行。

启动 3 次（`Start-Process` 启动 `dist/FirpeCleaner.exe`，轮询 `MainWindowHandle`），**3 次均出现窗口**：

| 启动 | PID | 窗口标题 | Responding | 窗口句柄 | 结果 |
|---|---|---|---|---|---|
| 1 | 40696 | `FirPE Disk Cleaner` | True | 7930738 | 窗口出现，无崩溃 |
| 2 | 7232 | `FirPE Disk Cleaner` | True | 7997272 | 窗口出现，无崩溃 |
| 3 | 27760 | `FirPE Disk Cleaner` | True | 32049588 | 窗口出现，持续存活 20s+，无崩溃 |

- 启动 3 全程监控：窗口出现后继续观察 20 秒，进程存活且 Responding=True（截图已存
  `firpe-cleaner/dist/smoke-launch.png`，49KB）；
- Windows 事件日志（Application：Application Error / .NET Runtime / Windows Error Reporting）
  在测试时间窗内**无任何 FirpeCleaner 崩溃记录**；
- 说明：非提权 shell 无法 `Stop-Process` 提权进程（Access denied），验证窗口由用户/环境自行关闭；
  进程退出均无崩溃事件佐证，判定**启动不崩**（GUI 窗口稳定出现）。

## 5. README.md 摘要

`firpe-cleaner/README.md`（FirPE 集成说明，中文）：

- **FirPE 集成**：`dist/FirpeCleaner.exe` 复制到 U 盘 `FirPE\Desktop\` → 服务器进 PE 后桌面双击（单文件零依赖）；
- **使用流程**：列盘（自动排除 USB/CD/系统盘/容量<1GB，可清理盘默认全选）→ `Clean Selected Disks`
  → 确认弹窗逐盘列出（盘号/型号/容量）→ diskpart `select disk N` + `clean`（仅 clean 非 clean all）
  → 成功提示 `Disks cleaned. Ready to reinstall.` / 失败逐条列出；
- **真机验证步骤**：① FirPE 启动 → 桌面双击 → 列盘确认（SAS/SCSI 盘识别、U 盘排除、
  系统盘排除）② 清理 → ③ DiskGenius 核实盘为未初始化；
- **注意事项**：界面全 ASCII；日志/失败明细可能含中文（PE 无中文字体显示方块，**不影响功能**，
  判定基于关键字匹配）；破坏性操作需逐盘核对；需管理员权限（manifest 内置 requireAdministrator）。

## 6. Commit

- message（brief 指定）：`docs(firpe-cleaner): 发布脚本 + FirPE 集成 README`
- 范围：仅 `firpe-cleaner/publish.ps1` + `firpe-cleaner/README.md` + 本报告；`dist/` 由
  `.gitignore` 排除不入库；未改任何代码；未 push。

## Concerns

- **本机无法复现 PE 真机环境**：启动验证只覆盖"窗口出现不崩"；FirPE 内的 SAS 盘识别、
  排除行为、diskpart clean 执行需按 README 真机验证步骤在服务器上完成（本机唯一盘为系统盘，
  且按约束不真 clean 本机盘）。
- **UAC 交互**：本机非提权 shell 启动发布 exe 依赖 UAC 批准（会话内自动批准）；FirPE 内以
  管理员运行无此问题。
- **日志含中文方块**：属设计内预期（README 已注明），不影响 clean 判定。
