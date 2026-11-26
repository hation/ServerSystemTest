using System;
using System.IO;
using System.Windows;
using System.Windows.Threading;
using HandyControl.Controls;

namespace FirpeCleaner;

public partial class App : Application
{
    /// <summary>主题偏好目录（%AppData%\FirpeCleaner\），仅存 theme.txt；异常日志已改走 exe 同目录。</summary>
    private static string LogDir =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "FirpeCleaner");

    /// <summary>主题偏好文件（内容 "dark"/"light"，跨会话记忆）。</summary>
    private static string ThemeFile => Path.Combine(LogDir, "theme.txt");

    public static App? CurrentApp => Current as App;

    public bool IsDarkTheme { get; private set; }

    protected override void OnStartup(StartupEventArgs e)
    {
        Program.BootLog("A0 进入 OnStartup");
        base.OnStartup(e);
        Program.BootLog("A1 base.OnStartup 后");

        // 全局异常兜底：避免默认崩溃框 / 静默退出
        DispatcherUnhandledException += OnDispatcherUnhandledException;

        // 深色模式：启动时按记忆的偏好应用主题（在窗口创建前）
        ApplyTheme(LoadThemePreference());
        Program.BootLog("A2 ApplyTheme 后");

        var w = new MainWindow();   // 若构造抛异常且 A2 已写出 → 死在 MainWindow 构造/XAML 解析
        Program.BootLog("A3 new MainWindow() 前");
        w.Show();
        Program.BootLog("A4 w.Show() 后");
    }

    /// <summary>全局未捕获异常处理：error.log 写 exe 同目录（FirPE 里 U 盘目录可写；
    /// %AppData% 的 X: 盘可能不可写/重启丢失）+ Growl 提示。诊断期不吞异常（e.Handled=false），
    /// 让 WPF 默认崩溃处理继续，便于定位静默退出死点。</summary>
    private void OnDispatcherUnhandledException(object sender, DispatcherUnhandledExceptionEventArgs e)
    {
        try
        {
            File.AppendAllText(Path.Combine(AppContext.BaseDirectory, "error.log"),
                $"[{DateTime.Now:yyyy-MM-dd HH:mm:ss}] {e.Exception}{Environment.NewLine}");
        }
        catch { /* 日志写失败不再抛，避免二次异常 */ }
        try { Growl.Error("An unhandled error occurred and was logged. Restart the app if the UI becomes unstable."); }
        catch { /* 界面线程不可用时忽略 */ }
        e.Handled = false;   // 不吞异常：诊断期需要默认崩溃框/进程终止作为最后痕迹，定位死点
    }

    /// <summary>切换浅色/深色主题并即时生效，且持久化偏好。
    /// HC 的语义画笔在 XAML 里 o:Freeze="True"（首次解析后永久冻结），运行时无法让已创建控件
    /// 重渲染，故运行时切换必须三步：
    /// ①换皮肤容器 → ②重新加载 HC Theme.xaml 新实例（新冻结画笔按新皮肤解析）→ ③重建主窗口。
    /// 主窗口重建：ShutdownMode=OnLastWindowClose，先 Show 新窗口再 Close 旧窗口，避免误触发退出。</summary>
    public void ApplyTheme(bool dark)
    {
        IsDarkTheme = dark;

        // 1) 换皮肤容器
        var skin = dark ? HandyControl.Data.SkinType.Dark : HandyControl.Data.SkinType.Default;
        var wrapper = Resources.MergedDictionaries[0];   // App.xaml 皮肤容器
        wrapper.MergedDictionaries.Clear();
        wrapper.MergedDictionaries.Add(HandyControl.Tools.ResourceHelper.GetSkin(skin));

        // 2) 重新加载 HC Theme.xaml（新实例＝新冻结画笔按新皮肤解析）
        var themeUri = new Uri("pack://application:,,,/HandyControl;component/Themes/Theme.xaml", UriKind.Absolute);
        for (var i = 0; i < Resources.MergedDictionaries.Count; i++)
            if ((Resources.MergedDictionaries[i].Source?.ToString() ?? "").EndsWith("/HandyControl;component/Themes/Theme.xaml", StringComparison.Ordinal))
            {
                Resources.MergedDictionaries[i] = new ResourceDictionary { Source = themeUri };
                break;
            }

        // 3) 重建主窗口（新窗口按新皮肤+新Theme解析，即时生效；保留位置）
        if (MainWindow is MainWindow mw && mw.IsLoaded)
        {
            var bounds = mw.RestoreBounds;
            var w = new MainWindow();
            if (bounds != Rect.Empty)
            {
                w.WindowStartupLocation = WindowStartupLocation.Manual;
                w.Left = bounds.Left;
                w.Top = bounds.Top;
            }
            w.Show();   // 先显示新窗口（保持 ≥1 窗口，OnLastWindowClose 不会触发退出）
            mw.Close(); // 再关旧窗口
        }

        SaveThemePreference(dark);
    }

    private static bool LoadThemePreference()
    {
        try
        {
            if (File.Exists(ThemeFile)) return File.ReadAllText(ThemeFile).Trim() == "dark";
        }
        catch { }
        return false;
    }

    private static void SaveThemePreference(bool dark)
    {
        try
        {
            Directory.CreateDirectory(LogDir);
            File.WriteAllText(ThemeFile, dark ? "dark" : "light");
        }
        catch { /* 写失败不影响使用 */ }
    }
}
