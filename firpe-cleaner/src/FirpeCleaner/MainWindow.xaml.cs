using System;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using HandyControl.Controls;

namespace FirpeCleaner;

public partial class MainWindow : HandyControl.Controls.Window
{
    public MainWindow()
    {
        InitializeComponent();
    }

    private void OnLoaded(object sender, RoutedEventArgs e)
    {
        FitToScreen();   // 窗口显示后（句柄/监视器 DPI 已确定）按屏幕收窄，避免内容被裁
        ThemeBtn.Content = App.CurrentApp?.IsDarkTheme == true ? "主题：深色" : "主题：浅色";
    }

    // ---------------- 脚手架占位：清理流程（列盘/勾选/强确认/diskpart）在后续任务实现 ----------------

    private void Start_Click(object sender, RoutedEventArgs e)
    {
        AppendLog("脚手架占位：清理流程将在后续任务实现（Task 4）。");
        Growl.Info("脚手架占位：清理流程将在后续任务实现。");
    }

    private void Stop_Click(object sender, RoutedEventArgs e)
    {
        // 占位：无运行中任务
    }

    private void Danger_Click(object sender, RoutedEventArgs e)
    {
        // 强确认骨架（ConfirmDialog 保留，Task 4 可能复用/简化）
        if (ConfirmDialog.Show("该操作将清理选中磁盘，无法恢复。", "确认执行")) Start_Click(sender, e);
    }

    private void OpenResult_Click(object sender, RoutedEventArgs e)
    {
        // 占位：Task 4 后展示清理结果
    }

    private void ThemeBtn_Click(object sender, RoutedEventArgs e)
    {
        var app = App.CurrentApp;
        if (app == null) return;
        app.ApplyTheme(!app.IsDarkTheme);   // 换肤会重建主窗口（新窗口按新主题渲染，即时生效）
    }

    private void AppendLog(string line)
    {
        Dispatcher.Invoke(() =>
        {
            LogBox.AppendText(line + Environment.NewLine);
            LogBox.ScrollToEnd();
        });
    }

    // SystemParameters.WorkArea 按系统 DPI(96) 返回；WPF 布局按窗口所在监视器 DPI 缩放，
    // 两者不一致时按系统 DPI 收窄会失效（如 96 系统 DPI + 150% 监视器缩放）。
    private void FitToScreen()
    {
        var hwnd = new WindowInteropHelper(this).Handle;
        var dpi = GetDpiForWindow(hwnd);
        if (dpi == 0) return;
        var scale = dpi / 96.0;
        var wa = SystemParameters.WorkArea;               // 系统 DPI(96) 单位
        var targetW = wa.Width / scale;                   // 布局 DIP
        var targetH = wa.Height / scale;
        if (Width > targetW) Width = targetW;
        if (Height > targetH) Height = targetH;
        // 收窄后显式居中（WindowStartupLocation 只在初始 Show 时按原始尺寸居中）
        Left = (targetW - Width) / 2;
        Top = (targetH - Height) / 2;
    }

    [DllImport("user32.dll")]
    private static extern uint GetDpiForWindow(IntPtr hwnd);
}
