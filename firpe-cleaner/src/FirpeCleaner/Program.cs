using System;
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
        SetProcessDpiAwarenessContext(PerMonitorV2);
        RenderOptions.ProcessRenderMode = RenderMode.SoftwareOnly;   // 避免硬件加速白屏

        var app = new App();
        app.InitializeComponent();
        app.Run();
    }
}
