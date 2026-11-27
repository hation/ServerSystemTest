# Task 9 报告 — FirPE 无法启动修复

- **状态**：DONE
- **Commit**：`a1a7791327f4426de9f10d620446d85d657a7262`
- **日期**：2026-11-26

## 根因（来自 brief）

1. 单文件 self-extract（`IncludeNativeLibrariesForSelfExtract` + `EnableCompressionInSingleFile`）
   启动时把内嵌 native DLL 解压到 `%TEMP%`（WinPE 的 X: 内存盘空间不足/不可写）→ 解压失败静默退出；
2. `requireAdministrator` 在 WinPE 无完整 UAC 机制，提权路径静默失败。

## 改动说明

| 文件 | 改动 |
| --- | --- |
| `src/FirpeCleaner/app.manifest` | `<requestedExecutionLevel level="requireAdministrator">` → `asInvoker`（FirPE 以 SYSTEM 运行本有最高权限，去掉 UAC 提权路径）；保留 `dpiAwareness=PerMonitorV2` |
| `src/FirpeCleaner/FirpeCleaner.csproj` | 去掉 `EnableCompressionInSingleFile=true`、`IncludeNativeLibrariesForSelfExtract=true`；`PublishSingleFile=true` → `false`（目录发布，native 库平铺直接加载零解压）；保留 `SelfContained=true`、`RuntimeIdentifier=win-x64`、`DebugType=none` |
| `publish.ps1` | 发布参数改 `-p:PublishSingleFile=false`，输出 `dist/FirpeCleaner/` 目录（含 exe + DLL）；产物校验改为 exe + `FirpeCleaner.Core.dll` 存在 + 统计 DLL 数量 |
| `README.md` | 发布说明与 FirPE 集成改为复制**整个** `dist/FirpeCleaner/` 目录到 `FirPE\Desktop\`（不是单个 exe）；权限说明改 `asInvoker` |

未改 Core/GUI 逻辑（纯发布配置调整）；未执行任何 diskpart clean（不真 clean）。

## 发布输出（dist 目录结构）

```
firpe-cleaner/dist/FirpeCleaner/
├── FirpeCleaner.exe            # 0.1 MB（apphost，非单文件壳）
├── FirpeCleaner.dll / FirpeCleaner.Core.dll
├── HandyControl.dll
├── coreclr.dll / hostfxr.dll / hostpolicy.dll / clrjit.dll 等运行时 native 库
├── WPF/框架 DLL（PresentationCore、PresentationFramework、System.Xaml 等）
└── {cs,de,es,fr,it,ja,ko,pl,pt-BR,ru,tr,zh-Hans,zh-Hant}/   # 本地化资源子目录
```

- 共 **246 个文件，约 146.2 MB**（self-contained 含运行时与全部语言资源）
- 嵌入 manifest 校验：发布 exe 内含 `asInvoker`，无 `requireAdministrator`

## 验证

| 项 | 结果 |
| --- | --- |
| `dotnet build FirpeCleaner.sln -c Release` | **0 warning 0 error** |
| `publish.ps1`（dotnet publish, `-p:PublishSingleFile=false`, `-o dist/FirpeCleaner`） | 成功，目录版（exe + 241 个 DLL） |
| 本机冒烟（非提权 Start-Process 启动发布 exe） | **通过**：6 秒后进程存活、主窗口 `FirPE Disk Cleaner` 出现（MainWindowHandle 非 0）、无崩溃，随后手动结束进程 |

> 说明：目录版 native 库与 exe 平铺同目录，WinPE 直接加载零解压；复制整个 `dist/FirpeCleaner/` 目录到 U 盘 `FirPE\Desktop\` 即可。真实 FirPE 环境验证仍需真机 U 盘确认（本机仅能验证普通 Windows 启动路径）。
