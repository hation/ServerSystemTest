# Task 8 brief — 日志同时输出到日志文件（落盘排查）

## 背景

firpe-cleaner 的日志目前只写 UI LogBox（`MainWindow.xaml.cs` 的 `AppendLog`），未落盘。
用户要求：**exe 的日志也输出一份到日志文件**，方便后续排查。

## 现状（已确认）

- `MainWindow.xaml.cs:200 AppendLog(string line)`：只 `LogBox.AppendText` + 截断 + ScrollToEnd
- `App.xaml.cs`：已有 `LogDir = %AppData%\FirpeCleaner\` 惯例（error.log、theme.txt 在那）
- 日志关键点（AppendLog 调用处）：扫描开始/盘数/扫描失败/确认取消/清理开始/清理完成/失败/异常

## 任务（精确，基于 HEAD=c23fdaa）

### 1. `firpe-cleaner/src/FirpeCleaner/MainWindow.xaml.cs`
- `AppendLog(string line)` 改为同时写日志文件：
  - 文件路径：`%AppData%\FirpeCleaner\cleanup.log`（复用 App.LogDir 思路；若目录不可写
    则 fallback exe 同目录 `FirpeCleaner.log`——FirPE 环境 %AppData% 在 X: 盘 PE 可写；
    U 盘不可写时写失败静默降级不阻断）
  - 每行带时间戳：`[yyyy-MM-dd HH:mm:ss] line`（UI 与文件都用带时间戳行，或 UI 保持原样、
    文件带时间戳——**推荐统一带时间戳**，方便排查时序）
  - 写失败静默（try/catch 忽略，不阻断 UI）
- 确认 LogDir 初始化：MainWindow 构造时 `Directory.CreateDirectory(LogDir)`

### 2. 验证
- `dotnet build` 0 warning 0 error
- 本机跑 exe 冒烟：操作几步（扫描/取消）→ 检查 `%AppData%\FirpeCleaner\cleanup.log`
  内容含对应日志行 + 时间戳
- 不真 clean

### 3. Commit
`feat(firpe-cleaner): 日志同时输出到日志文件（%AppData%\FirpeCleaner\cleanup.log 带时间戳，便于排查）`

## 环境

- dotnet 8 SDK；只改 firpe-cleaner/ 的 FirpeCleaner exe 项目

## 禁止

- 不改 Core；不真 clean 本机盘；不 push

## 报告

写 `firpe-cleaner/task8-report.md`：改动说明、本机冒烟（cleanup.log 内容验证）、commit hash。
返回：状态（DONE/BLOCKED）、commit hash、一行摘要、concerns。