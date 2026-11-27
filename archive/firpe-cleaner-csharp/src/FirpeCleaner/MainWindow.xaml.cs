using System.Collections.ObjectModel;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using FirpeCleaner.Core;
using HandyControl.Controls;

namespace FirpeCleaner;

/// <summary>
/// 盘列表行模型：包装 Core 的 DiskInfo，附带勾选状态（默认勾选全部可清理盘；
/// 排除盘不勾选且复选框禁用，状态列显示排除原因）。
/// </summary>
public sealed class DiskRow : INotifyPropertyChanged
{
    public DiskRow(DiskInfo info)
    {
        Info = info;
        _isChecked = !info.IsExcluded;   // 排除盘默认不勾选（其复选框同时被禁用）
    }

    public DiskInfo Info { get; }
    public int Number => Info.Number;
    public string Model => Info.Model;
    public string DiskName => "PhysicalDrive" + Info.Number;
    public string Bus => string.IsNullOrEmpty(Info.Bus) ? "-" : Info.Bus;
    public long SizeGB => Info.SizeGB;
    public string FreeText => Info.FreeGB is null ? "-" : Info.FreeGB.Value.ToString();
    public bool IsExcluded => Info.IsExcluded;
    public bool CanClean => !Info.IsExcluded;

    /// <summary>状态列文本（纯 ASCII；Core 排除原因为中文，此处映射为英文，PE 无中文字体）。
    /// 系统盘（IsBoot）不再排除，状态列标注 system/boot 供展示。</summary>
    public string Status => Info.IsExcluded
        ? TranslateExcludeReason(Info.ExcludeReason)
        : Info.IsBoot ? "Cleanable (system/boot)" : "Cleanable";

    private bool _isChecked;
    public bool IsChecked
    {
        get => _isChecked;
        set
        {
            if (_isChecked == value) return;
            _isChecked = value;
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(IsChecked)));
        }
    }

    /// <summary>Core 排除原因（中文常量）→ ASCII 状态文本；未知原因统一显示 "Excluded" 保证纯 ASCII。</summary>
    private static string TranslateExcludeReason(string reason)
    {
        return reason switch
        {
            "USB 移动盘" => "Excluded: USB removable",
            "可移动/CD/DVD 介质" => "Excluded: removable / CD / DVD",
            "容量未知" => "Excluded: size unknown",
            "容量小于 1GB" => "Excluded: size < 1GB",
            _ => "Excluded",
        };
    }

    public event PropertyChangedEventHandler? PropertyChanged;
}

/// <summary>主窗口：列盘（默认全选）→ 清理按钮 → 确认弹窗 → diskpart 清理 → 结果提示。</summary>
public partial class MainWindow : HandyControl.Controls.Window
{
    private readonly ObservableCollection<DiskRow> _disks = new();
    private bool _running;

    /// <summary>日志目录（%AppData%\FirpeCleaner\），与 App 全局异常日志（error.log）同目录惯例。</summary>
    private static string LogDir =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "FirpeCleaner");

    public MainWindow()
    {
        InitializeComponent();
        // 日志目录：FirPE 环境 %AppData% 在 X: 盘可写；目录不可写时不阻断启动（AppendLog 会回退 exe 同目录）
        try { Directory.CreateDirectory(LogDir); } catch { }
        // 注意：XAML 根元素上的 Loaded 属性事件在 hc:Window 下不可靠，与 disk-tests 一致用构造函数订阅
        Loaded += OnLoaded;
        Program.BootLog("W0 构造完成");
    }

    private void OnLoaded(object sender, RoutedEventArgs e)
    {
        Program.BootLog("W1 Loaded");
        FitToScreen();   // 窗口显示后（句柄/监视器 DPI 已确定）按屏幕收窄，避免内容被裁
        ThemeBtn.Content = App.CurrentApp?.IsDarkTheme == true ? "Theme: Dark" : "Theme: Light";
        DiskGrid.ItemsSource = _disks;
        LoadDisksAsync();
    }

    // ---------------- 盘列表加载 ----------------

    /// <summary>后台枚举磁盘 → 绑定列表；无盘/全排除 → 空状态 + 清理按钮禁用。</summary>
    private async void LoadDisksAsync()
    {
        Program.BootLog("W2 枚举开始");
        StatusText.Text = "Scanning disks...";
        AppendLog("Scanning disks...");
        try
        {
            var disks = await Task.Run(() => DiskEnumerator.Enumerate());
            _disks.Clear();
            foreach (var d in disks) _disks.Add(new DiskRow(d));

            var cleanable = _disks.Count(d => d.CanClean);
            DiskCountTitle.Text = _disks.Count == 0
                ? "Disks to clean"
                : $"Disks to clean ({cleanable} cleanable / {_disks.Count} total)";
            EmptyState.Visibility = cleanable == 0 ? Visibility.Visible : Visibility.Collapsed;
            CleanBtn.IsEnabled = cleanable > 0;
            StatusText.Text = _disks.Count == 0
                ? "No disk found."
                : cleanable == 0
                    ? "No cleanable disk (all excluded)."
                    : $"{cleanable} disk(s) ready.";
            AppendLog(cleanable == 0
                ? "No cleanable disk found. USB / CD / removable disks are excluded automatically."
                : $"Found {_disks.Count} disk(s), {cleanable} cleanable.");
            if (cleanable == 0)
                Growl.Warning("No cleanable disk found. USB / CD / removable disks are excluded automatically.");
        }
        catch (Exception ex)
        {
            StatusText.Text = "Disk scan failed.";
            AppendLog("Disk scan failed: " + ex.Message);
            Growl.Error("Disk scan failed: " + ex.Message);
        }
    }

    // ---------------- 清理流程 ----------------

    private async void Clean_Click(object sender, RoutedEventArgs e)
    {
        if (_running) return;
        var selected = _disks.Where(d => d.IsChecked && d.CanClean).ToList();
        if (selected.Count == 0)
        {
            Growl.Warning("No disk selected. Check disks in the list first.");
            return;
        }

        // 二次确认：列出选中盘（盘号/型号/容量），普通确认弹窗（无需输入文本）
        var prompt = "WARNING: The following disks will be cleaned. All data will be lost and cannot be recovered!";
        var lines = selected.Select(d =>
            "PhysicalDrive" + d.Number + " (" +
            (string.IsNullOrEmpty(d.Model) ? "" : d.Model + ", ") +
            d.SizeGB + " GB)").ToList();
        if (!ConfirmDialog.Show(prompt, lines))
        {
            AppendLog("Clean cancelled by user.");
            return;
        }

        SetRunning(true);
        var numbers = selected.Select(d => d.Number).ToList();
        StatusText.Text = "Cleaning...";
        AppendLog("Clean start: " + string.Join(", ", numbers.Select(n => "PhysicalDrive" + n)));
        try
        {
            var result = await Task.Run(() => new CleanRunner().Run(numbers));
            if (result.Success)
            {
                StatusText.Text = "Done";
                AppendLog($"Clean finished: {result.CleanedCount} disk(s) cleaned.");
                Growl.Success("Disks cleaned. Ready to reinstall.");
            }
            else
            {
                StatusText.Text = "Failed";
                AppendLog("Clean failed:");
                foreach (var f in result.Failures) AppendLog("  " + f);
                // 失败明细逐条列出（内容来自 Core/diskpart 原文，可能随系统语言变化）
                HandyControl.Controls.MessageBox.Show(
                    result.Failures.Count == 0
                        ? "Clean failed. See log for details."
                        : string.Join(Environment.NewLine, result.Failures),
                    "Clean failed", MessageBoxButton.OK, MessageBoxImage.Error);
                Growl.Error("Clean failed. See details.");
            }
        }
        catch (Exception ex)
        {
            StatusText.Text = "Error";
            AppendLog("Clean error: " + ex.Message);
            Growl.Error("Clean error: " + ex.Message);
        }
        finally
        {
            SetRunning(false);
        }
    }

    /// <summary>运行态锁定：清理中禁用清理按钮/盘列表/主题切换（disk-tests SetRunning 同构）。</summary>
    private void SetRunning(bool running)
    {
        _running = running;
        CleanBtn.IsEnabled = !running && _disks.Any(d => d.CanClean);
        DiskGrid.IsEnabled = !running;
        ThemeBtn.IsEnabled = !running;
    }

    // ---------------- 日志 / 主题 / 窗口 ----------------

    private void AppendLog(string line)
    {
        // UI 与日志文件统一带时间戳，方便排查时序
        var timestamped = $"[{DateTime.Now:yyyy-MM-dd HH:mm:ss}] {line}";
        LogBox.AppendText(timestamped + Environment.NewLine);
        if (LogBox.Text.Length > 200_000) LogBox.Text = LogBox.Text.Substring(LogBox.Text.Length / 2);
        LogBox.ScrollToEnd();
        AppendLogToFile(timestamped);
    }

    /// <summary>日志落盘（失败静默降级，不阻断 UI）：
    /// 优先 %AppData%\FirpeCleaner\cleanup.log；目录不可写时回退 exe 同目录 FirpeCleaner.log。</summary>
    private static void AppendLogToFile(string timestampedLine)
    {
        try
        {
            File.AppendAllText(Path.Combine(LogDir, "cleanup.log"), timestampedLine + Environment.NewLine);
        }
        catch
        {
            // %AppData% 不可写（如只读 U 盘环境）→ 回退 exe 同目录；再失败则静默忽略
            try
            {
                File.AppendAllText(Path.Combine(AppContext.BaseDirectory, "FirpeCleaner.log"),
                    timestampedLine + Environment.NewLine);
            }
            catch { /* 写日志失败不再抛，避免阻断 UI */ }
        }
    }

    private void ThemeBtn_Click(object sender, RoutedEventArgs e)
    {
        var app = App.CurrentApp;
        if (app == null) return;
        app.ApplyTheme(!app.IsDarkTheme);   // 换肤会重建主窗口（新窗口按新主题渲染，即时生效）
    }

    private void Window_Closing(object sender, CancelEventArgs e)
    {
        if (!_running) return;
        var ask = HandyControl.Controls.MessageBox.Show(
            "Cleaning is still in progress. Exiting now may leave disks in an inconsistent state. Exit anyway?",
            "FirPE Disk Cleaner", MessageBoxButton.YesNo, MessageBoxImage.Warning);
        if (ask != MessageBoxResult.Yes) e.Cancel = true;
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
