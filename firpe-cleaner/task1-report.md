# Task 1 报告 — FirpeCleaner 脚手架（复刻 gui-template 三层骨架）

日期：2026-11-26
状态：DONE

## 复制改名清单

源：`c:\Users\ganxin01\Documents\trae-work\disk-tests\gui-template\`
目标：`c:\Users\ganxin01\Documents\trae-work\ServerSystemTest\firpe-cleaner\`

| 模板（GuiTemplate） | 新（FirpeCleaner） | 处理 |
|---|---|---|
| `GuiTemplate.sln` | `FirpeCleaner.sln` | 复制+改名（项目名/路径全部替换） |
| `src/GuiTemplate/GuiTemplate.csproj` | `src/FirpeCleaner/FirpeCleaner.csproj` | 复制+改名（AssemblyName/RootNamespace/StartupObject/ProjectReference） |
| `src/GuiTemplate/Program.cs` | `src/FirpeCleaner/Program.cs` | 复制（DPI + 软件渲染防白屏），namespace 改名 |
| `src/GuiTemplate/App.xaml(.cs)` | `src/FirpeCleaner/App.xaml(.cs)` | 复制，namespace 改名；日志目录 `%AppData%\GuiTemplate` → `FirpeCleaner` |
| `src/GuiTemplate/MainWindow.xaml(.cs)` | `src/FirpeCleaner/MainWindow.xaml(.cs)` | 复制+精简（见下），Title 改名 |
| `src/GuiTemplate/ConfirmDialog.xaml(.cs)` | `src/FirpeCleaner/ConfirmDialog.xaml(.cs)` | 复制（保留，Task 4 可能复用/简化） |
| `src/GuiTemplate/Themes/DesignSystem.xaml` | `src/FirpeCleaner/Themes/DesignSystem.xaml` | 复制（无命名空间，原样） |
| `src/GuiTemplate/app.manifest` | `src/FirpeCleaner/app.manifest` | 复制（原样） |
| `src/GuiTemplate.Core/GuiTemplate.Core.csproj` | `src/FirpeCleaner.Core/FirpeCleaner.Core.csproj` | 复制+改名（RootNamespace） |
| `tests/GuiTemplate.Tests/GuiTemplate.Tests.csproj` | `tests/FirpeCleaner.Tests/FirpeCleaner.Tests.csproj` | 复制+改名（ProjectReference 路径） |

### 未复制 / 已删除（业务内容与残留）

- `src/bin/demo_task.ps1`、`src/bin/out/` —— PS 业务（本项目无 PS 业务，纯 C# 原生），不复制
- `tools/` —— 空目录，不复制
- 全部 `bin/`、`obj/` —— 编译残留，删除
- `src/FirpeCleaner.Core/ArgsBuilder.cs`、`ConfEditor.cs`、`ProcessRunner.cs` —— disk-tests PS/conf 业务，删除（Task 2/3 新建 DiskInfo/DiskEnumerator/CleanRunner）
- `tests/FirpeCleaner.Tests/ArgsBuilderTests.cs`、`ConfEditorTests.cs` —— 对应业务测试，删除

### MainWindow.xaml.cs 精简说明

模板 code-behind 引用 `ArgsBuilder`/`ProcessRunner`/`demo_task.ps1`（已删业务），
精简为可编译占位骨架：保留 `OnLoaded`（FitToScreen 屏幕适配）、主题切换、
`ConfirmDialog` 强确认演示、日志框 AppendLog；`Start_Click` 等按钮改为占位提示
（"清理流程将在后续任务实现（Task 4）"）。XAML 布局保持模板骨架原样（除 Title）。

## 三层结构

- `src/FirpeCleaner`（exe，net8.0-windows，WPF，HandyControl 3.5.1，引用 Core）
- `src/FirpeCleaner.Core`（类库 net8.0，不引用 WPF；Task 2 起填充业务类）
- `tests/FirpeCleaner.Tests`（xunit 2.9.2，引用 Core；当前 0 测试，Task 2 起填充）
- `FirpeCleaner.sln` 含三层（src/tests 解决方案文件夹同模板）
- 新增 `firpe-cleaner/.gitignore`（忽略 bin/、obj/、dist/，沿用仓库子项目惯例）

## 构建输出

`dotnet build firpe-cleaner/FirpeCleaner.sln`（dotnet SDK 8.0.426）：

```
FirpeCleaner.Core -> ...\FirpeCleaner.Core\bin\Debug\net8.0\FirpeCleaner.Core.dll
FirpeCleaner.Tests -> ...\FirpeCleaner.Tests\bin\Debug\net8.0\FirpeCleaner.Tests.dll
FirpeCleaner -> ...\FirpeCleaner\bin\Debug\net8.0-windows\win-x64\FirpeCleaner.dll

已成功生成。
    0 个警告
    0 个错误
```

`dotnet test firpe-cleaner/FirpeCleaner.sln`：运行正常（0 测试发现——模板业务测试已删，Task 2 填充）。

## Commit

`chore(firpe-cleaner): 脚手架（复刻 gui-template 三层骨架，改名 FirpeCleaner）`
commit hash：待 commit 后回填
