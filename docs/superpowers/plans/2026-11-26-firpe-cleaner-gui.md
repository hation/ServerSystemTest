# FirPE 一键清盘工具（GUI）实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 构建一个 WPF GUI 清盘工具（FirPE 桌面双击运行），列出可清理硬盘（排除 U 盘/CD/系统盘）、默认全选、显示类型/总容量/剩余容量，二次强确认后经 diskpart clean 清为未初始化。

**Architecture:** 三层 C#/.NET 8 方案（exe / Core / Tests），纯 Code-behind + DiskRow 行模型；GUI 调 Core 枚举（WMI 主 + diskpart 回退）与 diskpart 清理（子进程）。复刻 disk-tests/gui-template 骨架。

**Tech Stack:** C# / .NET 8 / WPF / HandyControl 3.5.1 / xunit（Core 单测）/ diskpart（WinPE 原生）/ dotnet publish 单文件 self-contained

**Spec:** [2026-11-26-firpe-cleaner-gui-design.md](file:///c:/Users/ganxin01/Documents/trae-work/ServerSystemTest/docs/superpowers/specs/2026-11-26-firpe-cleaner-gui-design.md)

**新工具目录：** `C:\Users\ganxin01\Documents\trae-work\ServerSystemTest\firpe-cleaner\`

## Global Constraints

- C# / .NET 8（net8.0-windows），WPF，HandyControl 3.5.1（NuGet）
- 三层：`src/FirpeCleaner`（exe）/ `src/FirpeCleaner.Core`（类库，不引用 WPF）/ `tests/FirpeCleaner.Tests`（xunit 只测 Core）
- 枚举：主 WMI `Win32_DiskDrive`，回退 diskpart `list disk`；不假设 WinPE 有 PowerShell
- 过滤：排除 InterfaceType=USB、MediaType Removable/CD/DVD、系统盘（IsSystem/IsBoot）、Size<1GB
- 清理：diskpart `/s` 脚本 `select disk N` + `clean`（**仅 clean，无深度清理 clean all**——用户明确不需要）
- GUI 全部用户可见文本纯 ASCII（PE 无中文字体风险，沿用 diskwipe-iso 教训）
- 发布：`dotnet publish -r win-x64 --self-contained -p:PublishSingleFile=true`
- 复刻起点：`c:\Users\ganxin01\Documents\trae-work\disk-tests\gui-template\`（复制→改名→换业务）

## Review Focus

1. **无盘/枚举失败**：GUI 应显示空状态提示而非崩溃（空枚举 → EmptyState + 原因显示）
2. **全部盘被排除**（只剩 U 盘/CD/系统盘）：应提示"无可清理盘"且清理按钮禁用
3. **diskpart 清理失败**（盘被占用/权限）：解析输出判断失败并显示原因，不误报成功
4. **WMI 缺失回退 diskpart**：枚举来源切换不影响过滤正确性（USB/CD 仍被排除）
5. **二次确认防误清**：确认弹窗列出每盘名称/盘号/容量，用户点确认才执行（普通 MessageBox，无输入文本）

---

### Task 1: 项目脚手架（复刻 gui-template 三层骨架）

**Files:**
- Create: `firpe-cleaner/FirpeCleaner.sln`
- Create: `firpe-cleaner/src/FirpeCleaner/FirpeCleaner.csproj`
- Create: `firpe-cleaner/src/FirpeCleaner.Core/FirpeCleaner.Core.csproj`
- Create: `firpe-cleaner/tests/FirpeCleaner.Tests/FirpeCleaner.Tests.csproj`
- Create: `firpe-cleaner/src/FirpeCleaner/Program.cs`、`App.xaml(.cs)`、`MainWindow.xaml(.cs)`、`ConfirmDialog.xaml(.cs)`、`Themes/DesignSystem.xaml`、`app.manifest`
- Copy 参考：`c:\Users\ganxin01\Documents\trae-work\disk-tests\gui-template\src\GuiTemplate\*`

**Interfaces:**
- Consumes: 无
- Produces: `FirpeCleaner.Core` 类库（后续 Task 引用）、`FirpeCleaner` exe 骨架（MainWindow 占位）

- [ ] **Step 1: 复制 gui-template 到 firpe-cleaner/ 并全局改名**

复制 `disk-tests/gui-template/` 整目录 → `firpe-cleaner/`；`GuiTemplate` → `FirpeCleaner`、`GuiTemplate.Core` → `FirpeCleaner.Core`、`GuiTemplate.sln` → `FirpeCleaner.sln`；删除 bin/obj 残留。

- [ ] **Step 2: 验证构建**

Run: `dotnet build firpe-cleaner/FirpeCleaner.sln`
Expected: 0 error（GUI 骨架可编译）

- [ ] **Step 3: Commit**

```bash
git add firpe-cleaner/
git commit -m "chore(firpe-cleaner): 脚手架（复刻 gui-template 三层骨架，改名 FirpeCleaner）"
```

---

### Task 2: Core 磁盘枚举（WMI 主 + diskpart 回退）

**Files:**
- Create: `firpe-cleaner/src/FirpeCleaner.Core/DiskInfo.cs`（行模型：Number/Device/Sn/Model/SizeGB/FreeGB/Bus/Media/IsHdd/IsExcluded/ExcludeReason/IsSelected）
- Create: `firpe-cleaner/src/FirpeCleaner.Core/DiskEnumerator.cs`（WMI 枚举 + diskpart 回退 + 过滤）
- Test: `firpe-cleaner/tests/FirpeCleaner.Tests/DiskEnumeratorTests.cs`

**Interfaces:**
- Consumes: Task 1 的 Core 项目骨架
- Produces: `DiskEnumerator.Enumerate() -> IReadOnlyList<DiskInfo>`（已过滤，含排除标记）、`DiskEnumerator.Filter(rows)`；`DiskInfo.FreeGB` 由 WMI 分区归并计算

- [ ] **Step 1: 写失败测试（WMI 解析 + 过滤）**

```csharp
[Fact] public void Filter_ExcludesUsbAndCdAndSystem() { ... 断言 USB/CD/系统盘被排除、其余保留、IsExcluded 标记 }
[Fact] public void ParseDiskpartOutput_ExtractsNumbersAndSizes() { ... 解析 list disk 文本 → 盘号/大小 }
```

- [ ] **Step 2: 运行测试确认失败**

Run: `dotnet test firpe-cleaner/tests/FirpeCleaner.Tests`
Expected: FAIL（类不存在）

- [ ] **Step 3: 实现 `DiskEnumerator`**

WMI `ManagementObjectSearcher("SELECT * FROM Win32_DiskDrive")` → DiskInfo；`FreeGB` 用 `Win32_DiskPartition`+`Win32_LogicalDisk` 归并；WMI 抛异常时回退解析 `diskpart /s`（脚本 `list disk`+`detail disk`）输出。过滤规则按 Global Constraints。

- [ ] **Step 4: 测试通过 + 本机验证枚举**

Run: `dotnet test` → PASS；再写临时控制台调用 Enumerate 打印本机盘（真实数据，验证过滤）。

- [ ] **Step 5: Commit**

```bash
git add firpe-cleaner/src/FirpeCleaner.Core firpe-cleaner/tests
git commit -m "feat(firpe-cleaner): Core 磁盘枚举（WMI 主+diskpart 回退+过滤）"
```

---

### Task 3: Core diskpart 清理执行器

**Files:**
- Create: `firpe-cleaner/src/FirpeCleaner.Core/CleanRunner.cs`
- Test: `firpe-cleaner/tests/FirpeCleaner.Tests/CleanRunnerTests.cs`

**Interfaces:**
- Consumes: Task 2 的 `DiskInfo`
- Produces: `CleanRunner.Run(diskNumbers) -> CleanResult`（含 per-disk 状态/日志；**仅 clean，无 deepClean 参数**）；`CleanResult.Success`/`Failures`/`Output`

- [ ] **Step 1: 写失败测试（脚本生成 + 输出解析）**

```csharp
[Fact] public void BuildScript_OneSelectCleanPerDisk() { ... 断言生成文本含 select disk N + clean（无 clean all） }
[Fact] public void ParseOutput_DetectsSuccessAndFailure() { ... "DiskPart successfully" 判定成功，错误关键字判定失败 }
```

- [ ] **Step 2: 运行测试确认失败**

Run: `dotnet test`
Expected: FAIL

- [ ] **Step 3: 实现 `CleanRunner`**

生成脚本到临时文件 → `Process.Start("diskpart", "/s:"+script)` 捕获输出 → 解析成功/失败。仅 `select disk N` + `clean`（无 deepClean）。破坏性操作，仅在调用方已确认后执行。

- [ ] **Step 4: 测试通过**

Run: `dotnet test` → PASS

- [ ] **Step 5: Commit**

```bash
git commit -m "feat(firpe-cleaner): Core diskpart 清理执行器（脚本生成+结果解析）"
```

---

### Task 4: GUI 主窗口（列盘 + 默认全选 + 清理按钮 + 结果提示）

**Files:**
- Modify: `firpe-cleaner/src/FirpeCleaner/MainWindow.xaml(.cs)`
- Modify: `firpe-cleaner/src/FirpeCleaner/ConfirmDialog.xaml(.cs)`
- Modify: `firpe-cleaner/src/FirpeCleaner/App.xaml(.cs)`

**Interfaces:**
- Consumes: Task 2 `DiskEnumerator`、Task 3 `CleanRunner`
- Produces: 完整 GUI（列盘 DataGrid / 默认全选 / 清理按钮 / ConfirmDialog 强确认 / 成功提示）

- [ ] **Step 1: MainWindow 布局**

DataGrid 列：勾选 CheckBox（默认全选）| 盘号 PhysicalDriveN | 类型 Bus | 总容量 SizeGB | 剩余容量 FreeGB | 状态（可清理/系统盘-排除）；空状态提示条；底部清理按钮 + 状态栏。

- [ ] **Step 2: 加载逻辑**

`OnLoaded` → `Task.Run(DiskEnumerator.Enumerate)` → 绑定 `ObservableCollection<DiskRow>`；排除盘不勾选且状态列标注；无盘/全部排除 → 空状态 + 按钮禁用。

- [ ] **Step 3: 清理流程**

按钮 → 收集选中盘 → 确认弹窗（普通 MessageBox，逐盘列出 名称/盘号/容量）→ 用户点确认 → `Task.Run(CleanRunner.Run)` → 结果（成功 Growl/失败列出）。

- [ ] **Step 4: GUI 冒烟（本机，dry-run）**

Run: `dotnet publish` 后本机跑 exe：列盘正常、勾选正常、确认弹窗正常；（本机不真 clean，用假 CleanRunner 或确认前可中断）。

- [ ] **Step 5: Commit**

```bash
git commit -m "feat(firpe-cleaner): GUI 主窗口（列盘/默认全选/强确认/清理/结果提示）"
```

---

### Task 5: 发布 + FirPE 集成打包

**Files:**
- Create: `firpe-cleaner/README.md`（使用/集成说明）
- Create: `firpe-cleaner/publish.ps1`（或 .cmd：dotnet publish 单文件）

**Interfaces:**
- Consumes: Task 4 完成 exe
- Produces: `firpe-cleaner/dist/FirpeCleaner.exe`（self-contained 单文件）+ FirPE 集成说明

- [ ] **Step 1: 写 publish 脚本并执行**

`dotnet publish src/FirpeCleaner -r win-x64 --self-contained -p:PublishSingleFile=true -o dist`
Expected: `dist/FirpeCleaner.exe` 单文件生成（~60-70MB）

- [ ] **Step 2: 写 README（FirPE 集成）**

exe 复制到 FirPE U 盘 `FirPE\Desktop\` → 桌面双击；真机验证步骤（列盘确认→清理→DiskGenius 核实）。

- [ ] **Step 3: Commit**

```bash
git commit -m "docs(firpe-cleaner): 发布脚本 + FirPE 集成 README"
```

---

## Self-Review

**Spec coverage:** 需求 6 项全部覆盖——列盘(Task2/4)、默认全选排除U盘CD(Task2/4)、类型/总容量/剩余容量(Task2/4)、清理按钮(Task4)、二次确认(Task4)、成功提示(Task4)。技术选型/三层结构/发布(Task1/5)。✓
**Step scan:** 每步一个可检查动作。✓
**Type consistency:** DiskInfo/CleanRunner/DiskEnumerator 跨 Task 一致。✓
**Review Focus:** 5 项全部有测试或 GUI 兜底（空枚举→EmptyState；全排除→禁用；清理失败→解析显示；回退→过滤不变；强确认→输入文本）。✓
**Proportion:** 计划 ≈ spec 规模。✓

（本计划为 Draft，待用户确认 spec 后按 subagent-driven 执行；每个 Task 由独立 subagent 实现、新 reviewer 复查后进入下一个，结尾整支复查。）
