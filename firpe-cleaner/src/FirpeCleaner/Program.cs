using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;

namespace FirpeCleaner;

/// <summary>
/// 自定义入口：在创建 WPF 窗口前声明高 DPI 感知并强制软件渲染。
/// Debug 构建不带 app.manifest（manifest 仅 Release 生效，含 requireAdministrator），
/// 若无此调用，Debug 下窗口按 96DPI 布局被系统放大，小屏/高缩放下超出屏幕。
/// Release 由 app.manifest 的 dpiAwareness=PerMonitorV2 声明，此处重复调用无害。
/// 强制软件渲染：VM/远程桌面/部分显卡驱动下 WPF 硬件加速(D3D)present 失败会导致整窗白屏，
/// 本类工具非图形密集，软件渲染可稳定兜底。
/// </summary>
public static class Program
{
    [DllImport("user32.dll")]
    private static extern bool SetProcessDpiAwarenessContext(IntPtr value);

    // DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2
    private static readonly IntPtr PerMonitorV2 = new(-4);

    [STAThread]
    public static void Main()
    {
        BootLog("M0 进入 Main");
        SetProcessDpiAwarenessContext(PerMonitorV2);
        BootLog("M1 SetProcessDpiAwarenessContext 后");
        RenderOptions.ProcessRenderMode = RenderMode.SoftwareOnly;   // 避免硬件加速白屏
        BootLog("M2 RenderOptions 后");

        BootLog("M3 new App() 前");
        var app = new App();   // 若此处抛异常且 M3 已写出 → 死在 new App()（XAML 解析层）
        app.InitializeComponent();
        BootLog("M4 app.InitializeComponent() 后");
        BootLog("M5 app.Run() 前");
        app.Run();
    }

    /// <summary>
    /// 启动打点日志：写 exe 同目录（AppContext.BaseDirectory）startup.log，
    /// 追加 + 时间戳；写失败静默 try/catch，绝不影响启动。
    /// FirPE 场景：若 M0 都未写出 → 进程死在 hostfxr/加载器层（缺 DLL/依赖），
    /// 与 WPF 无关；若只有 M0-M2 → 死在 new App()/XAML 解析前。
    /// </summary>
    public static void BootLog(string msg)
    {
        try
        {
            File.AppendAllText(Path.Combine(AppContext.BaseDirectory, "startup.log"),
                $"[{DateTime.Now:yyyy-MM-dd HH:mm:ss}] {msg}{Environment.NewLine}");
        }
        catch { /* 打点写失败静默，不阻断启动 */ }
    }
}
