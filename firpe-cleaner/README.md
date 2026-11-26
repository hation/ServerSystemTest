# FirpeCleaner — FirPE 一键清盘工具

WPF 图形化清盘工具：列出服务器硬盘（自动排除 U 盘 / CD / 系统盘）、默认全选可清理盘，
二次强确认后经 `diskpart clean` 把选中盘清为**未初始化**（不含分区/文件系统，可直接重装）。

- 运行环境：WinPE / FirPE（桌面双击，管理员权限，diskpart 为 PE 原生组件）
- 构建：C# / .NET 8 / WPF（HandyControl），self-contained 单文件 exe，**零 .NET 依赖**
- 界面文本全部为 ASCII 英文（PE 无中文字体风险）

## 发布

```powershell
# 仓库根执行（firpe-cleaner/ 目录下）
powershell -NoProfile -ExecutionPolicy Bypass -File publish.ps1
```

产物：`firpe-cleaner/dist/FirpeCleaner.exe`（win-x64 自包含单文件，约 68 MB，离线可运行）。
脚本参数：`-r win-x64 --self-contained true -p:PublishSingleFile=true -p:EnableCompressionInSingleFile=true`；
`IncludeNativeLibrariesForSelfExtract` 已在 csproj 内置（WinPE 下 WPF/原生库自解压可运行）。

## FirPE 集成

1. 把 `dist/FirpeCleaner.exe` 复制到 FirPE U 盘根目录的 `FirPE\Desktop\` 文件夹
2. 服务器从该 U 盘启动进入 FirPE
3. 桌面上双击 `FirpeCleaner.exe`（PE 内默认管理员权限，直接运行）

> 只需一个 exe，无其他文件（单文件自包含）。

## 使用流程

1. **列盘**：启动后自动枚举本机硬盘，可清理盘**默认全选**；
   U 盘（USB 移动盘）、CD/DVD、系统盘/启动盘、容量 <1GB 的盘显示在列表中但**自动排除**
   （勾选禁用，状态列标注排除原因），避免误清。
2. **清理**：确认勾选的盘无误后，点击 `Clean Selected Disks` 按钮。
3. **确认弹窗**：弹出强确认对话框，逐盘列出 盘号（PhysicalDriveN）/ 型号 / 容量；
   点击 `Clean` 才真正执行（点 `Cancel` 中止，不执行任何操作）。
4. **执行**：后台调用 diskpart `select disk N` + `clean`（**仅 clean，非 clean all**）。
5. **成功提示**：全部成功 → 状态 `Done` + 提示 `Disks cleaned. Ready to reinstall.`；
   任一失败 → 逐条列出失败明细，可在日志区查看完整输出。

## 真机验证步骤（FirPE）

1. **FirPE 启动** → 桌面双击 `FirpeCleaner.exe` → 列盘：
   - 确认目标 SAS 盘（SCSI/SAS 总线）出现在列表且被勾选；
   - 确认 U 盘（USB）被排除（勾选禁用、状态列显示 `Excluded: USB removable`）；
   - 确认系统盘/启动盘被排除（若 PE 从数据盘启动）。
2. **清理**：勾选目标盘 → `Clean Selected Disks` → 确认弹窗核对盘号/容量 → `Clean`。
3. **核实**：清理完成后用 DiskGenius 打开对应盘 → 显示为**未初始化**（无分区），即成功。

## 注意事项

- **破坏性操作**：`clean` 会永久删除盘上所有数据且不可恢复，务必在确认弹窗中逐盘核对。
- **界面全 ASCII**：窗口标题、按钮、状态、日志、弹窗均为英文；PE 无中文字体也不会显示乱码方块。
- **日志可能含中文**：diskpart 输出/失败明细可能随系统语言含中文，PE 无中文字体时显示为方块，
  **不影响功能**（判定基于关键字匹配，非显示文本）。
- **仅 clean 非 clean all**：只清空分区表为未初始化，不做深度覆写（速度优先，符合清盘重装场景）。
- **权限**：需管理员权限运行（Release 构建内置 `requireAdministrator`，PE 默认满足）。
- **GUI 文本不可 ASCII 兜底项**：CleanRunner 失败明细来自 diskpart 原文，随系统语言变化，属预期。

## 源码结构

```
firpe-cleaner/
├── publish.ps1                  # 发布脚本（self-contained 单文件）
├── src/FirpeCleaner/            # WPF exe（GUI：列盘/全选/确认/清理/结果提示）
├── src/FirpeCleaner.Core/       # 类库（WMI 枚举 + diskpart 回退 + 清理执行，无 WPF 依赖）
└── tests/FirpeCleaner.Tests/    # xunit 单测（只测 Core）
```

构建 SDK：.NET 8（`dotnet build FirpeCleaner.sln`）。测试：`dotnet test tests/FirpeCleaner.Tests`。
