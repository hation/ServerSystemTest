# Task 1 brief — FirpeCleaner 脚手架（复刻 gui-template 三层骨架）

## 背景

新工具 FirPE 一键清盘 GUI（firpe-cleaner），基于 disk-tests/gui-template（WPF/.NET 8/HandyControl）复刻。本任务：脚手架——复制模板改名，可编译。

## 需求来源

- Spec：`docs/superpowers/specs/2026-11-26-firpe-cleaner-gui-design.md`
- Plan：`docs/superpowers/plans/2026-11-26-firpe-cleaner-gui.md` Task 1

## 任务（精确）

### 1. 复制模板 → 改名
- 源：`c:\Users\ganxin01\Documents\trae-work\disk-tests\gui-template\`
- 目标：`c:\Users\ganxin01\Documents\trae-work\ServerSystemTest\firpe-cleaner\`
- 全局改名：`GuiTemplate` → `FirpeCleaner`、`GuiTemplate.Core` → `FirpeCleaner.Core`、
  `GuiTemplate.sln` → `FirpeCleaner.sln`（sln/csproj/命名空间/文件名/引用）
- 删除 bin/obj 残留（模板编译产物不复制）
- 保留模板的：Program.cs（DPI+软件渲染防白屏）、App.xaml(.cs)、MainWindow.xaml(.cs) 骨架、
  ConfirmDialog.xaml(.cs)（保留，Task 4 可能复用/简化）、Themes/DesignSystem.xaml、app.manifest
- 模板里 `demo_task.ps1`、`bin/` 与业务相关的内容不复制（本项目无 PS 业务，纯 C# 原生）

### 2. 三层结构
- `src/FirpeCleaner/FirpeCleaner.csproj`（exe，net8.0-windows，WPF，引用 Core，HandyControl）
- `src/FirpeCleaner.Core/FirpeCleaner.Core.csproj`（类库，不引用 WPF）
- `tests/FirpeCleaner.Tests/FirpeCleaner.Tests.csproj`（xunit，引用 Core）
- `FirpeCleaner.sln`（含三层）

### 3. 验证构建
- `dotnet build firpe-cleaner/FirpeCleaner.sln` → 0 error
- 可选：`dotnet test`（模板自带 1 个示例测试若保留则过）

### 4. Commit
`chore(firpe-cleaner): 脚手架（复刻 gui-template 三层骨架，改名 FirpeCleaner）`

## 环境

- Windows 侧 dotnet（SDK 8.0+ 需可用——若 dotnet 不在 PATH，用 `C:\Program Files\dotnet\dotnet.exe`）
- 仓库根：`c:\Users\ganxin01\Documents\trae-work\ServerSystemTest`（git 已初始化）
- 只新增 firpe-cleaner/ 目录，不动其他

## 禁止

- 不改业务逻辑（MainWindow 保持模板占位即可，Task 4 再改）
- 不改文档/其他目录
- 不 push

## 报告

写 `firpe-cleaner/task1-report.md`：复制改名清单、构建输出、commit hash。
返回：状态（DONE/BLOCKED）、commit hash、一行摘要、concerns。