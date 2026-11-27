# FirPE + DiskGenius 一键清理方案评估

日期：2026-11-26
状态：待用户核对（可行性已联网评估）

---

## 1. 方案概述

放弃 diskwipe-iso（可启动 ISO 清盘工具，已归档至 `diskwipe-iso/ARCHIVE.md`），
改用：**FirPE（Windows PE 启动盘）+ DiskGenius 命令行清盘 API + 打包成 exe 放入
FirPE 一键执行**，实现服务器全部硬盘数据清除（恢复为未初始化）。

核心思路：服务器从 FirPE U 盘启动进入 WinPE → 自动/一键运行我们的 exe →
exe 调用 DiskGenius 命令行（或 diskpart）枚举并清除所有非启动盘 → 完成。

---

## 2. 可行性评估（联网确认）

### 2.1 FirPE 侧 —— ✅ 完全可行（官方支持）

| 能力 | 确认方式 | 结论 |
|------|---------|------|
| 预装 DiskGenius | FirPE 官方：预装 Ghost、DISM++、**DiskGenius**、EasyRC 等装机必备工具 | ✅ 免集成 |
| 自定义 exe 到桌面 | `U盘:\FirPE\Desktop\` 放 .exe/.lnk，PE 启动后自动显示桌面 | ✅ 官方文档 |
| **自动运行程序** | `U盘:\FirPE\Startup\` 放 exe，WinPE 启动后**自动执行** | ✅ 官方文档（满足"一键"） |
| 生命周期钩子 | Hooks 目录脚本实现开机自动化 | ✅ 官方文档 |
| 插件生态 | 兼容 Edgeless/HotPE 插件体系 | ✅ 扩展性强 |

### 2.2 DiskGenius 侧 —— GUI 能力齐全，但命令行 API 验证结论：不支持 ⚠️

**对用户提供的 DiskGenius 包（DG6201829_x64.zip，V6.2.0.1829）做了实际验证**：
- 解包：只有 `DiskGenius.exe`（GUI）+ DLL 组件，**无独立 dgcmd.exe / 命令行工具**
- 字符串分析 `DiskGenius.exe`（ASCII + UTF-16）：无 `/cmd` `/script` `/batch`
  `commandline` `dgcmd` 等命令行参数处理；大量 `/XX`（/AG /AI /AM…）为**内部命令
  ID/快捷键**，非 CLI 开关
- releasenote.txt（GBK）：全为 GUI 功能更新，无命令行说明
- 联网：官网三版本（免费/标准/专业）共用同一 GUI 发行包，**官方无公开独立命令行版**
  下载，手册亦无 dgcmd 脚本语法文档

**结论**：DiskGenius GUI 具备"删除所有分区 / 清除扇区数据 / 批量格式化"（免费版），
但**不支持命令行脚本自动化**（用户原意的"DiskGenius 一键清理 API"在免费 GUI 包中
不可用）。

**应对（关键决策重估）**：
- **主力改用 Windows 原生 diskpart**（WinPE 内置，100% 命令行、官方、免费、可靠）：
  `select disk N` + `clean` = 删除全部分区/签名恢复未初始化（与 wipefs -a 等价）
  + 可选 `clean all`（全盘清零，深度不可恢复）
- **DiskGenius 降级为人工 GUI 兜底**（FirPE 预装，现场人工操作）或 **AutoHotkey
  驱动其 GUI**（模拟快捷键"删除所有分区→保存"，可行但脆弱，不推荐作主力）
- exe 打包：调用 diskpart 脚本 + 二次确认（输入 YES），完全满足"一键清盘"

### 2.3 exe 打包 —— ✅ 可行

- **AutoHotkey / AutoIt**：轻量，可打包独立 exe，调用 DiskGenius/dgcmd/diskpart
  批处理 + 简单确认框（输入 YES 二次确认）
- **C# / .NET（Publish 单文件）**：WinPE 可运行，做 GUI 确认界面 + 调用命令行
- **批处理 .cmd + 简单 exe 壳**：最轻量方案

### 2.4 核心优势（对比已放弃的 ISO 方案）

| 维度 | diskwipe-iso（已放弃） | FirPE+DiskGenius |
|------|----------------------|-----------------|
| 磁盘识别 | Linux 内核枚举 PCI，真机 SAS 控制器枚举失败（DIAG SAS 空），软件不可解 | WinPE 厂商驱动 + 厂商主板支持，DiskGenius/diskpart 直接读盘 |
| 驱动 | 手工提取 Kylin 内核模块，依赖链易错 | FirPE 预装/自动加载 |
| 开发量 | initramfs + 引导 + 内核全套自造 | 只写一个调用脚本/exe |
| 排障 | 屏幕乱码、无日志通道 | PE 环境成熟，日志可落 U 盘 |
| 风险 | 已 30+ 轮未解决真机识别 | 低（成熟工具链） |

---

## 3. 待你确认的关键决策

### 决策 1：清盘执行器（核心，已基于实测更新）
- **A. Windows 原生 diskpart（✅ 推荐，已验证可行）**：WinPE 内置，
  `list disk` → 逐盘 `select disk N` + `clean`（清分区表+签名 = 恢复未初始化）/
  可选 `clean all`（全盘清零）；exe 调用 diskpart /s:脚本，零第三方依赖
- **B. DiskGenius（⚠️ 已实测：免费 GUI 包无命令行 API）**：仅作 FirPE 人工 GUI 兜底，
  或 AutoHotkey 驱动 GUI（脆弱，不推荐作主力）
- **C. 两者结合**：diskpart 主力清分区表 + 可选 DiskGenius 清除扇区数据（深度擦除，
  慢，447GiB 需数小时）

### 决策 2：一键触发方式
- **A. 自动运行**：exe 放 `FirPE\Startup\`，进 PE 后自动弹出确认界面 → 输入 YES 执行
- **B. 桌面手动**：exe 放 `FirPE\Desktop\`，桌面双击执行（与 FirPE 原装 DiskGenius 共存）

### 决策 3：清盘目标（默认全盘 vs 排除启动 U 盘）
- **A. 排除启动 U 盘**（推荐）：枚举物理盘排除 USB 启动盘，只清内置 SAS/NVMe/SATA 盘
- **B. 全盘（含 U 盘）**：按用户勾选

### 决策 4：清盘强度
- **A. 清分区表（快速）**：diskpart clean / DiskGenius 删除所有分区 ≈ 恢复未初始化（原
  wipefs 方案语义）
- **B. 清分区表 + 扇区覆盖（深度）**：DiskGenius 清除扇区数据，数据不可恢复（慢，SAS
  447GiB 全盘覆盖需数小时）

---

## 4. 下一步（确认后）

1. 下载 DiskGenius，实测 dgcmd 命令行能力（决策 1 的 A 选项）
2. 按决策实现 exe（AHK/批处理/C#）+ 二次确认（输入 YES）
3. FirPE U 盘制作 + exe 放入对应目录
4. 真机验证（服务器启动 FirPE → 一键 → 盘清空）

---

## 参考来源

- [FirPE 官方帮助文档（个性化配置：自定义桌面/自动运行程序）](https://docs.firpe.cn/feature/configguide/)
- [FirPE 插件生态](https://docs.firpe.cn/advanced/plugins/)
- [FirPE 维护系统官网（预装 DiskGenius 等）](https://fir-pe.com/)
- [DiskGenius 官网（删除所有分区/清除扇区数据/批量格式化）](https://www.diskgenius.cn/help/disk.php)
- [DiskGenius 使用手册 PDF](https://diskgenius.cn/help/DiskGenius%20%E7%94%A8%E6%88%B7%E4%BD%BF%E7%94%A8%E6%89%8B%E5%86%8C.pdf)
- [DiskGenius Erase Sectors 官方说明](https://www.diskgenius.com/manual/erase-sectors.php)
- [Windows PE 自定义脚本（Winpeshl.ini/Startnet.cmd，Microsoft）](https://learn.microsoft.com/en-us/previous-versions/windows/embedded/ff794514(v=winembedded.1001))
