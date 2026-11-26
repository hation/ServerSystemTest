# Task 10 报告 — 启动打点诊断版（定位 FirPE 静默退出死点）

状态：**DONE**

## 打点位置说明

日志统一写 **exe 同目录**（`AppContext.BaseDirectory`，FirPE 里 U 盘目录可写；`%AppData%` 的 X: 盘可能不可写/重启丢失）。

### 1. `src/FirpeCleaner/Program.cs`
- 新增 `public static void BootLog(string msg)`：追加写 `AppContext.BaseDirectory/startup.log`，带时间戳；写失败静默 try/catch，绝不阻断启动。
- `Main()` 逐层打点：
  - `M0 进入 Main`（方法首行）
  - `M1 SetProcessDpiAwarenessContext 后`
  - `M2 RenderOptions 后`
  - `M3 new App() 前`（打点在 new 之前——若 new App() 抛异常，M3 仍已落盘）
  - `M4 app.InitializeComponent() 后`
  - `M5 app.Run() 前`
- 判定：**M0 都未写出 → 进程死在 hostfxr/加载器层**（缺 DLL/依赖）；止于 M2 → 死在 new App()/XAML 解析层。

### 2. `src/FirpeCleaner/App.xaml.cs`
- `OnStartup` 打点：`A0 进入 OnStartup` / `A1 base.OnStartup 后` / `A2 ApplyTheme 后` / `A3 new MainWindow() 前`（打点在 new 之前）/ `A4 w.Show() 后`。
- `OnDispatcherUnhandledException` 修改：
  - error.log 改写 **`AppContext.BaseDirectory/error.log`**（原写 `%AppData%`，FirPE 不可写/重启丢失）。
  - **`e.Handled = false`**（原为 true 吞掉全部异常致静默退出）；注释说明诊断期不吞异常，让 WPF 默认崩溃处理继续作为最后痕迹。
  - MainWindow 构造异常会触发此 handler → error.log 落盘同目录。

### 3. `src/FirpeCleaner/MainWindow.xaml.cs`
- `W0 构造完成`（构造函数末尾，`InitializeComponent` + Loaded 订阅后）
- `W1 Loaded`（OnLoaded 首行）
- `W2 枚举开始`（LoadDisksAsync 首行）
- 若卡在 XAML 解析/构造则只有 A3 前的 marker，无 W0。

### 4. `publish.ps1`
- 发布后新增 zip 打包：`Compress-Archive` 压缩 `dist/FirpeCleaner/` → `dist/FirpeCleaner-diag.zip`（内含 `FirpeCleaner/` 文件夹层级，解压即得完整目录版，用户拷贝用）。

## 验证结果

- `dotnet build -c Release`：**0 警告 0 错误**。
- 本机运行 `dist/FirpeCleaner/FirpeCleaner.exe`（正常运行 12 秒后强制结束，未触发清理流程，无 error.log）。

### 本机 startup.log 内容（正常路径，全部 marker）

```
[2026-11-26 16:12:03] M0 进入 Main
[2026-11-26 16:12:03] M1 SetProcessDpiAwarenessContext 后
[2026-11-26 16:12:03] M2 RenderOptions 后
[2026-11-26 16:12:03] M3 new App() 前
[2026-11-26 16:12:04] M4 app.InitializeComponent() 后
[2026-11-26 16:12:04] M5 app.Run() 前
[2026-11-26 16:12:04] A0 进入 OnStartup
[2026-11-26 16:12:04] A1 base.OnStartup 后
[2026-11-26 16:12:04] A2 ApplyTheme 后
[2026-11-26 16:12:04] W0 构造完成
[2026-11-26 16:12:04] A3 new MainWindow() 前
[2026-11-26 16:12:04] W1 Loaded
[2026-11-26 16:12:04] W2 枚举开始
[2026-11-26 16:12:04] A4 w.Show() 后
```

时序说明：`W0`（构造完成）出现在 `A3`（new 之前）与 `A4`（Show 后）之间、`W1/W2`（Show 触发的 Loaded 及其中异步枚举）紧随其后，属预期——A3 打点后 new MainWindow() 触发构造（W0），w.Show() 触发 Loaded（W1→W2），最后回到 A4。

## 产物路径

- 发布目录：`firpe-cleaner/dist/FirpeCleaner/`（exe 0.1 MB，目录 241 个 DLL，self-contained 目录版）
- **zip：`firpe-cleaner/dist/FirpeCleaner-diag.zip`（67.3 MB）**

## Commit

- message：`feat(firpe-cleaner): 启动打点诊断（startup.log 逐层 marker + 异常落盘不吞，定位 FirPE 静默退出死点）`
- hash：本 commit（`git rev-parse HEAD`），本文档与诊断代码同一 commit 提交。

## Concerns

- 未真 clean、未 push（按约束）。
- 打点仅覆盖启动链路（Main/OnStartup/MainWindow 构造与加载），运行期异常仍走 error.log（同目录、不吞）。
- `LogDir`（%AppData%）保留用于 theme.txt 主题偏好；仅 error.log 迁移到 exe 同目录。
