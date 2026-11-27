# Task 5 brief — 发布 + FirPE 集成打包

## 背景

firpe-cleaner 发布为 self-contained 单文件 exe，并提供 FirPE 集成说明（U 盘 `FirPE\Desktop\` 桌面双击）。

## 需求来源

- Plan：`docs/superpowers/plans/2026-11-26-firpe-cleaner-gui.md` Task 5

## 任务（精确，基于 HEAD=87e1b30）

### 1. `firpe-cleaner/publish.ps1`（发布脚本）
- `dotnet publish src/FirpeCleaner/FirpeCleaner.csproj -r win-x64 --self-contained true -p:PublishSingleFile=true -p:EnableCompressionInSingleFile=true -o dist`
- 输出 `dist/FirpeCleaner.exe`（单文件，~60-70MB）
- 加 `-p:IncludeNativeLibrariesForSelfExtract=true` 或默认；确保 WinPE 可运行

### 2. 执行发布
- 运行 publish.ps1 → dist/FirpeCleaner.exe 生成
- 验证：文件存在、大小合理、可启动（本机双击/命令行启动不崩——GUI 窗口出现）

### 3. `firpe-cleaner/README.md`（集成与使用说明）
- **FirPE 集成**：exe 复制到 FirPE U 盘 `FirPE\Desktop\` → 服务器进 PE 后桌面双击
- **使用流程**：列盘（排除 U 盘/CD/系统盘默认全选）→ 清理按钮 → 确认弹窗 → diskpart clean → 成功提示
- **真机验证步骤**：① FirPE 启动 → 桌面双击 → 列盘确认（识别 SAS 盘、排除 U 盘）
  ② 清理 → ③ DiskGenius 手动核实盘已未初始化
- **注意事项**：全 ASCII 界面；日志/输出可能含中文（PE 无中文字体显示方块，不影响功能）

### 4. Commit
`docs(firpe-cleaner): 发布脚本 + FirPE 集成 README`

## 环境

- dotnet 8 SDK；只改 firpe-cleaner/（publish.ps1、README.md、dist 不入库——.gitignore 已含 dist）

## 禁止

- 不改代码逻辑；不真 clean 本机盘；不 push
- dist/ 不入库（.gitignore）

## 报告

写 `firpe-cleaner/task5-report.md`：发布输出、exe 大小、本机启动验证、README 摘要、commit hash。
返回：状态（DONE/BLOCKED）、commit hash、一行摘要、concerns。