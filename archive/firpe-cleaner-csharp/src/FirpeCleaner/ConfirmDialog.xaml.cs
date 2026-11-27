using System.Windows;
using System.Windows.Controls;

namespace FirpeCleaner;

/// <summary>
/// 普通确认对话框：列出选中盘（盘号/型号/容量）+ 确定/取消按钮，无需输入文本。
/// 用法：if (ConfirmDialog.Show("提示", new[] { "PhysicalDrive0 ..." })) { ... }
/// </summary>
public partial class ConfirmDialog : HandyControl.Controls.Window
{
    public bool Confirmed { get; private set; }

    private ConfirmDialog(string prompt, IReadOnlyList<string> lines)
    {
        InitializeComponent();
        PromptText.Text = prompt;
        DiskList.ItemsSource = lines;
    }

    public static bool Show(string prompt, IReadOnlyList<string> lines)
    {
        var dlg = new ConfirmDialog(prompt, lines) { Owner = Application.Current.MainWindow };
        dlg.ShowDialog();
        return dlg.Confirmed;
    }

    private void Ok_Click(object sender, RoutedEventArgs e)
    {
        Confirmed = true;
        Close();
    }

    private void Cancel_Click(object sender, RoutedEventArgs e) => Close();
}
