# Task 10 brief — 启动打点诊断版（定位 FirPE 静默退出死在哪层）

## 背景

FirPE 里双击 FirpeCleaner.exe 无反应（已修 asInvoker + 目录发布仍无效）。CMD 无输出。
**当前代码隐患**：App.xaml.cs `OnDispatcherUnhandledException` 设 `e.Handled=true` 吞掉
全部异常，且 error.log 写 `%AppData%`（FirPE 的 X: 盘可能不可写/重启丢失）→ 崩溃变
"静默退出"且无痕迹。
**诊断方案**：启动链路每个关键层写打点日志到 **exe 同目录**（AppContext.BaseDirectory，
FirPE 里 U 盘目录可写），异常不吞、落盘同目录。用户跑一次，日志文件定位死在哪层。

## 任务（精确，基于 HEAD=4571e06）

### 1. `firpe-cleaner/src/FirpeCleaner/Program.cs`：启动打点
- 新增 `static void BootLog(string msg)`：写 `AppContext.BaseDirectory/startup.log`
  （追加 + 时间戳；写失败静默 try/catch）
- Main() 逐层打点（每个 marker 一行）：
  - M0 进入 Main
  - M1 SetProcessDpiAwarenessContext 后
  - M2 RenderOptions 后
  - M3 new App() 前
  - M4 app.InitializeComponent() 后
  - M5 app.Run() 前
- 若 M0 都未写出 → 进程死在 hostfxr/加载器层（缺 DLL/依赖）

### 2. `firpe-cleaner/src/FirpeCleaner/App.xaml.cs`：OnStartup 打点 + 异常不吞落盘
- OnStartup 打点：A0 进入 OnStartup、A1 base.OnStartup 后、A2 ApplyTheme 后、
  A3 new MainWindow() 前、A4 w.Show() 后
- `OnDispatcherUnhandledException` 改：
  - error.log 写**同目录**（AppContext.BaseDirectory/error.log），不再写 %AppData%
  - **e.Handled = false**（不吞，让异常继续/WPF 默认处理，避免静默）——或改为
    写日志后 **e.Handled=false**；注释说明：诊断期不吞异常，便于定位
- MainWindow 构造异常会触发此 handler → error.log 落盘

### 3. `firpe-cleaner/src/FirpeCleaner/MainWindow.xaml.cs`：构造打点
- 构造函数末尾、OnLoaded、LoadDisksAsync 前各打点（W0 构造完成、W1 Loaded、
  W2 枚举开始）——若卡在 XAML 解析/构造则只有 A3 前的 marker

### 4. 重新发布（目录版）+ 打包 zip
- publish.ps1 重新发布 dist/FirpeCleaner/（含诊断代码）
- 压缩 dist/FirpeCleaner/ → dist/FirpeCleaner-diag.zip（用户拷贝用）

### 5. 验证
- dotnet build 0 warning 0 error
- 本机跑 exe：确认 startup.log 生成且含 M0-M5+A0-A4+W0-W2 全部 marker（正常路径）
- 不真 clean

### 6. Commit
`feat(firpe-cleaner): 启动打点诊断（startup.log 逐层 marker + 异常落盘不吞，定位 FirPE 静默退出死点）`

## 环境

- dotnet 8 SDK（PATH 或 C:\Program Files\dotnet\dotnet.exe）；只改 firpe-cleaner/

## 禁止

- 不改 Core；不真 clean；不 push

## 报告

写 `firpe-cleaner/task10-report.md`：打点位置说明、本机 startup.log 内容、zip 路径、commit hash。
返回：状态（DONE/BLOCKED）、commit hash、一行摘要、concerns。