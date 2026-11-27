# FirPE 一键清盘工具（GUI）设计文档

日期：2026-11-26
状态：待用户核对
关联：基于 disk-tests 的 gui-template（WPF/.NET 8）复刻；替代已放弃的 diskwipe-iso

---

## 1. 需求（用户原话整理）

FirPE（WinPE）U 盘启动 → 桌面双击 exe（方案一）→ GUI：

1. **列出可清理的盘**：展示硬盘类型、总容量、剩余容量
2. **默认全选**：除 U 盘、CD 盘外全部默认勾选
3. **清理按钮**：点击触发
4. **二次确认**：列出被选中盘名称，用户确认
5. **确认后清理**：diskpart 执行清盘
6. **成功后提示**

UI 参考 `C:\Users\ganxin01\Documents\trae-work\disk-tests`（diskcheck-gui 工具，WPF/.NET 8/HandyControl）。

---

## 2. 技术选型（复用 disk-tests 架构）

| 项 | 选型 | 依据 |
|----|------|------|
| 语言/框架 | C# / .NET 8 / WPF | disk-tests 同栈 |
| UI 控件库 | HandyControl 3.5.1 | disk-tests 同栈 |
| 结构 | 三层：src/CleanGui（exe）/ src/CleanGui.Core（类库）/ tests（xunit 只测 Core） | gui-template 同构 |
| 启动入口 | Program.cs（DPI + 软件渲染防白屏）→ App.xaml → MainWindow.xaml | disk-tests 同构 |
| 模式 | 纯 Code-behind + 行模型 `DiskRow : INotifyPropertyChanged` | disk-tests 约定 |
| 打包 | `dotnet publish -r win-x64 --self-contained -p:PublishSingleFile=true` | disk-tests 发布方式 |
| 复刻起点 | 复制 `disk-tests/gui-template` 整目录 → 全局改名 → 换业务逻辑 | Explore 报告建议 |

---

## 3. UI 架构（搬自 disk-tests）

- **MainWindow.xaml**：三行 Grid
  - 顶部：盘列表区（Border 包 DataGrid + 空状态提示条）
  - 中部：TabControl（清理 / 工具 / 配置 3 Tab）——或简化为单 Tab 清理
  - 底部：状态栏 + 清理按钮
- **ConfirmDialog.xaml(.cs)**：强确认对话框（必须输入指定文本才执行）——高危清理标配
- **App.xaml**：皮肤容器 + HC Theme + `Themes/DesignSystem.xaml`（设计 token）
- 主题三步法、DPI/白屏兜底：disk-tests 同构

### 盘列表 DataGrid 列定义
| 列 | 数据 |
|----|------|
| 勾选（CheckBox） | 默认全选 |
| 盘号 | PhysicalDrive N |
| 类型 | 总线类型（SAS/SATA/NVMe/USB…） |
| 总容量 | GB |
| 剩余容量 | GB |
| 状态 | 可清理 / 系统盘(排除) |

---

## 4. 磁盘枚举与过滤（关键安全设计）

**核心原则（吸取 diskwipe-iso 教训）：不假设环境，多策略回退**。

**枚举（多策略回退，全部原生）**：
- **主策略 WMI `Win32_DiskDrive`**（FirPE 为完整维护 PE，一般含 WinPE-WMI 组件）：
  - `InterfaceType`（USB/SCSI/SATA/NVMe/IDE）、`Size`（总容量）、`MediaType`
  （Fixed Hard Disk / Removable Media）、`Model`、`Index`（→ PhysicalDriveN）
- **回退策略 diskpart `list disk`**（WinPE **100% 必带**，官方原生）：
  解析 `list disk` 输出拿盘号/大小；接口类型用 `detail disk`（含总线信息）。
  - 判定策略：先试 WMI，拿不到（WMI 缺失）自动回退 diskpart 解析——GUI 显示来源标记
- **剩余容量**：WMI `Win32_DiskDrive` 无剩余容量字段 → 用 `Win32_DiskPartition`+
  `Win32_LogicalDisk` 按盘归并计算；拿不到显示"—"（不阻塞，总容量+类型已满足主需求）
- **CD/光驱**：`Win32_CDROMDrive` 与 `Win32_DiskDrive` 中 MediaType/InterfaceType
  为 CD/DVD 的排除；`list disk` 中光驱单独列出（diskpart 可识别）

**过滤（默认全选，排除）**：
1. `InterfaceType = "USB"`（U 盘）→ 排除
2. MediaType 为 Removable / CD / DVD（CD 盘）→ 排除
3. 系统盘（IsSystem/IsBoot，WinPE 启动盘）→ 排除（DiskRow 状态列标"系统盘-排除"）
4. 剩余容量无意义的小盘（<1GB）→ 排除（参考 disk-tests 的 Size>1GB 口径）

**清理执行（diskpart，WinPE 必带）**：
```
list disk
select disk N
clean          ← 清分区表+签名=未初始化（对应 wipefs -a）
```
- 每选中盘一条 select+clean（**仅 clean，无深度清理 clean all 功能**——用户明确不需要）
- 生成脚本 → `diskpart /s:clean.txt` 运行 → 解析输出确认成功

---

## 5. 交互流程（用户需求逐步）

```
[进入 PE] → 桌面双击 exe
  → 加载：WMI 枚举磁盘 → 过滤（排除 USB/CD/系统盘）→ 默认全选
  → 列表显示：勾选 | 盘号 | 类型 | 总容量 | 剩余容量 | 状态
  → 用户点 [清理选中磁盘] 按钮
  → 确认弹窗：列出被选中盘名称/盘号/容量（普通确认框，无需输入文本）
  → 用户确认 → 生成 diskpart 脚本 → diskpart /s 执行 → 进度显示
  → 成功提示（Growl / 结果窗口）："磁盘已清理完成，恢复为未初始化"
  → 用户可退出（提示可断电/重启）
```

---

## 6. 安全设计（防误操作，参考 disk-tests）

1. **默认全选仅含可清理盘**：USB/CD/系统盘硬排除（WMI InterfaceType/MediaType 过滤）
2. **二次确认弹窗**：普通确认框列出选中盘名称/盘号/容量，用户点确认才执行（无需输入文本）
3. **运行态锁定**：清理中禁用按钮/关闭拦截（disk-tests SetRunning 同构）
4. **结果核验**：清理后重新枚举确认盘已无分区（可选）
5. **日志落 U 盘**：FirPE 环境日志写 U 盘 `cleanup.log`

---

## 7. 打包与集成（FirPE）

- 发布单文件 exe（self-contained，~60-70MB）
- 放入 FirPE U 盘 `FirPE\Desktop\` → 桌面双击（方案一）
- 可附带 `FirPE\Startup\` 自动运行（后续可选）

---

## 8. 验证计划（不真机盲测）

| 阶段 | 验证 |
|------|------|
| 单元测试 | Core 层：磁盘过滤逻辑、diskpart 脚本生成、结果解析（xunit，本机可跑） |
| GUI 冒烟 | 本机 Windows 跑 exe：列盘/勾选/确认/（dry-run 不真 clean） |
| 真机（用户执行） | FirPE U 盘 → 桌面双击 → 列盘确认（识别 SAS 盘、排除 U 盘）→ 清理 → DiskGenius 核实 |

---

## 9. 已确认项（实现前定稿）

1. **剩余容量**：WMI 分区归并；拿不到显示"—"（不阻塞）
2. **二次确认**：普通确认弹窗列出选中盘（用户已确认，无需输入文本）
3. **深度清理**：不需要（用户已确认隐藏），仅 `clean` 清分区表
4. **UI**：参考 disk-tests（gui-template 复刻），列盘/默认全选/类型/总容量/剩余容量
