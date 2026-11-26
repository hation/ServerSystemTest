using System.Windows;
using HandyControl.Controls;

namespace FirpeCleaner;

/// <summary>
/// 危险操作强确认对话框：必须输入指定文本（如"确认执行"）才允许执行。
/// 用法：if (ConfirmDialog.Show("提示", "确认执行")) { ... }
/// </summary>
public partial class ConfirmDialog : HandyControl.Controls.Window
{
    private readonly string _required;
    public bool Confirmed { get; private set; }

    private ConfirmDialog(string prompt, string required)
    {
        InitializeComponent();
        _required = required;
        PromptText.Text = prompt;
        RequiredText.Text = $"请输入「{required}」以确认执行：";
        InfoElement.SetPlaceholder(InputBox, required);
    }

    public static bool Show(string prompt, string required)
    {
        var dlg = new ConfirmDialog(prompt, required) { Owner = Application.Current.MainWindow };
        dlg.ShowDialog();
        return dlg.Confirmed;
    }

    private void Ok_Click(object sender, RoutedEventArgs e)
    {
        if (InputBox.Text.Trim() != _required)
        {
            Growl.Warning($"输入不匹配，请输入「{_required}」才能执行。");
            InputBox.Focus();
            return;
        }
        Confirmed = true;
        Close();
    }

    private void Cancel_Click(object sender, RoutedEventArgs e) => Close();
}
