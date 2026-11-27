# Task 1 审查报告 — FirpeCleaner 脚手架

日期：2026-11-26
审查对象：commit `849b90ee9b44c7d5e2748c42ef5ec67a57d28a7f`（HEAD）
审查方式：只读审查（未修改任何文件）
结论：**Approved**（含 2 项 Minor 观察，不阻塞）

---

## 逐项审查

### 1. 三层结构 ✅
- `src/FirpeCleaner/FirpeCleaner.csproj`：`OutputType=WinExe`、`net8.0-windows`、`UseWPF=true`、HandyControl 3.5.1、`ProjectReference → FirpeCleaner.Core` ✅
- `src/FirpeCleaner.Core/FirpeCleaner.Core.csproj`：`net8.0` 纯类库，无 UseWPF、无 WPF 包引用、无 WPF 类型引用 ✅
- `tests/FirpeCleaner.Tests/FirpeCleaner.Tests.csproj`：xunit 2.9.2 + Microsoft.NET.Test.Sdk + runner，`ProjectReference → Core`（路径 `..\..\src\FirpeCleaner.Core\`）✅
- `FirpeCleaner.sln`：含 FirpeCleaner.Core / FirpeCleaner / FirpeCleaner.Tests 三个项目，src/tests 解决方案文件夹嵌套与模板同构 ✅

### 2. 全局改名彻底 ✅
- Grep `GuiTemplate`（全 firpe-cleaner 目录）：命中 11 行，全部位于 `task1-report.md` 的改名清单表格（文档描述），**代码/sln/csproj/命名空间/引用中 0 残留**
- AssemblyName/RootNamespace/StartupObject/ProjectReference 与模板逐字段比对仅改名，其余保持

### 3. 骨架保留正确 ✅
- `Program.cs`：`SetProcessDpiAwarenessContext(PerMonitorV2)` + `RenderOptions.ProcessRenderMode = SoftwareOnly`（DPI+软件渲染防白屏）✅
- `App.xaml.cs`：主题三步法（换皮肤容器 → 重载 HC Theme.xaml → 重建主窗口）、全局未捕获异常兜底、主题偏好持久化 ✅
- `App.xaml`：皮肤容器（index 0）→ HC Theme.xaml（index 1）→ `Themes/DesignSystem.xaml`，顺序与换肤代码契约一致 ✅
- `MainWindow.xaml(.cs)`：OnLoaded FitToScreen（GetDpiForWindow 按实际 DPI 收窄）、主题切换、ConfirmDialog 强确认演示、AppendLog 日志；Start/Stop/OpenResult 为占位 ✅
- `ConfirmDialog.xaml(.cs)`：强确认（输入指定文本）保留，Task 4 可复用/简化 ✅
- `Themes/DesignSystem.xaml`：原样保留 ✅
- `app.manifest`：requireAdministrator + PerMonitorV2（Release 生效）✅

### 4. 业务内容已删 ✅
- 模板 `src/bin/demo_task.ps1`（已确认源存在）未复制；`src/bin/out/`、`tools/` 未复制
- `ArgsBuilder.cs` / `ConfEditor.cs` / `ProcessRunner.cs` 及对应测试 `ArgsBuilderTests.cs` / `ConfEditorTests.cs` 已删
- Grep `demo_task|ArgsBuilder|ConfEditor|ProcessRunner`：命中 4 行，全部位于 task1-report.md 说明文字，**代码 0 残留**

### 5. .gitignore ✅
- `bin/`、`obj/`、`dist/` 三项齐全；`git ls-files firpe-cleaner` 确认无任何 bin/obj 产物被跟踪

### 6. dotnet build 可信 ✅
- 实测 `dotnet build firpe-cleaner/FirpeCleaner.sln`（SDK 8.0.426）：**0 警告 / 0 错误**，输出与报告一致
- 三个项目依次构建成功（Core → Tests → FirpeCleaner）

### 7. 未动其他目录、未 push ✅
- `git show 849b90e --stat`：仅 firpe-cleaner/ 下 15 个文件（+660 行），无其他目录改动
- `git status -sb`：`main...origin/main [ahead 30]`，HEAD 未推送 ✅

---

## 问题列表

### Critical
无。

### Important
无。

### Minor（观察项，不阻塞，Task 4 重写 MainWindow 时自然消失）
1. `MainWindow.xaml` 第 52 行保留模板 UI 文案「真实项目此处改为 run_erase.ps1 / run_reset.ps1 等」——为模板 PS 业务脚本名的占位提示文本残留，与「纯 C# 原生」项目定位不符；因 brief 允许 MainWindow 保持模板占位，可接受，建议 Task 4 一并清理。
2. `MainWindow.xaml` 参数卡占位残留：`ParamBox Text="demo"`、`ProgressText "0/3"`（模板 3 步任务计数）、DryRun CheckBox——均为模板演示占位，Task 4 替换为盘列表/清理流程时覆盖。

---

## 结论

**Approved**。三层结构、改名、骨架、业务清理、.gitignore、构建（实测 0 error 0 warning）、范围与推送状态全部合规；2 项 Minor 占位文案残留不阻塞，Task 4 改 MainWindow 时一并处理即可。
