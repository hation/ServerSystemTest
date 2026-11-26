# Task 8 报告 — 日志同时输出到日志文件（落盘排查）

## 状态：DONE

## 改动说明

文件：`firpe-cleaner/src/FirpeCleaner/MainWindow.xaml.cs`（仅改 FirpeCleaner exe 项目，未改 Core）

- `AppendLog(string line)` 改为：
  - UI 与日志文件**统一带时间戳** `[yyyy-MM-dd HH:mm:ss]`，方便排查时序；
  - 追加写入 `%AppData%\FirpeCleaner\cleanup.log`（复用 App.xaml.cs 的 LogDir 惯例，与 error.log/theme.txt 同目录）；
  - 目录/写入失败时 **try/catch 静默降级**：先回退 exe 同目录 `FirpeCleaner.log`（`AppContext.BaseDirectory`），再失败则静默忽略，不阻断 UI；
  - 新增 `LogDir` 静态属性（`Environment.SpecialFolder.ApplicationData` + `FirpeCleaner`），并加 `using System.IO;`。
- `MainWindow` 构造函数：`Directory.CreateDirectory(LogDir)`（try/catch 包裹，目录不可写时不阻断启动，由 AppendLog 回退）。

注释为中文，与现有代码风格一致。

## 构建验证

`dotnet build FirpeCleaner.sln -c Debug`（dotnet 8 SDK）：
**0 个警告，0 个错误**，已成功生成。

## 本机冒烟（不真 clean）

通过 UI Automation 驱动本机 exe（Debug 输出 `src\FirpeCleaner\bin\Debug\net8.0-windows\win-x64\FirpeCleaner.exe`）：
启动自动扫描 → 点击 "Clean Selected Disks" → 确认弹窗出现 → 点击 "Cancel"（未执行任何清理，CleanRunner 仅在确认后才运行）。

`%AppData%\FirpeCleaner\cleanup.log`（本机为 `C:\Users\ganxin01\AppData\Roaming\FirpeCleaner\cleanup.log`）内容验证：

```
[2026-11-26 13:56:28] Scanning disks...
[2026-11-26 13:56:29] Found 1 disk(s), 1 cleanable.
[2026-11-26 13:56:39] Clean cancelled by user.
```

- 扫描日志行（开始/盘数）与取消日志行均已落盘；
- 每行带 `[yyyy-MM-dd HH:mm:ss]` 时间戳；
- 本机 %AppData% 可写，走主路径 cleanup.log，未触发 fallback（exe 同目录 FirpeCleaner.log 未生成）。

## Commit

- message：`feat(firpe-cleaner): 日志同时输出到日志文件（%AppData%\FirpeCleaner\cleanup.log 带时间戳，便于排查）`
- hash：`<待 docs 回填>`

## Concerns

- 无。写失败静默降级已覆盖 FirPE X: 盘 %AppData% 可写与 U 盘不可写两种场景。
