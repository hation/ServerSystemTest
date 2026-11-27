/* FirPE Native Probe
 * 最小原生 Win32 探针：验证「原生 exe 在 FirPE 中可运行」的方向。
 * 启动即写 probe.log 到 exe 同目录；带 -auto 参数则不弹窗（自动化验证用）。
 * 编译：TCC -mwindows，x86/x64 双版本。
 */
#include <windows.h>
#include <stdio.h>
#include <string.h>

/* 拼接 exe 同目录下的文件名（避免 cwd 变化导致日志位置漂移） */
static void make_path(char* buf, const char* name)
{
    char exe[MAX_PATH];
    DWORD len = GetModuleFileNameA(NULL, exe, MAX_PATH);
    if (len == 0) { strcpy(buf, name); return; }
    char* slash = strrchr(exe, '\\');
    if (slash) *slash = '\0';
    sprintf(buf, "%s\\%s", exe, name);
}

static void log_line(const char* line)
{
    char path[MAX_PATH];
    make_path(path, "probe.log");
    FILE* f = fopen(path, "a");
    if (f) { fprintf(f, "%s\n", line); fclose(f); }
}

int WINAPI WinMain(HINSTANCE hInstance, HINSTANCE hPrevInstance, LPSTR lpCmdLine, int nCmdShow)
{
    log_line("started");
    if (lpCmdLine && strstr(lpCmdLine, "-auto"))
    {
        log_line("done(auto)");
        return 0;
    }
    MessageBoxA(NULL,
        "Native probe OK. If you see this message box,\n"
        "the native exe runs fine on this system.",
        "FirPE Native Probe", MB_OK);
    log_line("done");
    return 0;
}
