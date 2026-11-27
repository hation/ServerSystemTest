/* FirPE Disk Cleaner - 原生 Win32 骨架（纯 C + TCC 编译，可在 WinPE 环境运行）
 * 本文件只搭 UI 骨架：主窗口、ListView、状态文本、按钮、日志框。
 * 业务逻辑（磁盘枚举、diskpart 清理）由后续任务接入。
 * 注意：全部界面字符串为 ASCII；注释用中文。
 */
#include <windows.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include "app.h"
#include "disks.h"
#include "diskpart.h"
#include "driver.h"

/* 控件 ID */
#define IDC_LISTVIEW 101
#define IDC_STATUS   102
#define IDC_CLEAN    103
#define IDC_LOGBOX   104

/* 自定义消息：worker 线程清理完成，通知主线程更新结果 */
#define WM_APP_CLEAN_DONE (WM_APP + 1)
/* 自定义消息：驱动自愈 worker 线程完成，通知主线程更新状态 */
#define WM_APP_DRIVER_DONE (WM_APP + 2)

/* 窗口类与标题（ASCII） */
#define APP_TITLE   "FirPE Disk Cleaner"
#define APP_CLASS   "FirpeCleanerWndClass"
#define APP_WIDTH   900
#define APP_HEIGHT  580

/* 中文界面文案（GBK 字节转义——ANSI 控件 SetWindowTextA/CreateWindowExA
 * 不能直接用 UTF-8 源码字面量；字节值已用 .NET GBK 936 实测）。
 * 按钮/状态栏必须配宋体 g_logFont 渲染（Fixedsys 无中文字形）。 */
#define CN_CLEAR        "\xC7\xE5\xB3\xFD"                    /* 清除 */
#define CN_CLEANING     "\xC7\xE5\xB3\xFD\xD6\xD0"            /* 清除中 */
#define CN_DONE         "\xCD\xEA\xB3\xC9"                    /* 完成 */
#define CN_FAILED       "\xCA\xA7\xB0\xDC"                    /* 失败 */
#define CN_READY        "\xBE\xCD\xD0\xF7"                    /* 就绪 */
#define CN_SCANNING     "\xD5\xFD\xD4\xDA\xC9\xA8\xC3\xE8\xB4\xC5\xC5\xCC" /* 正在扫描磁盘 */
#define CN_NO_DISK      "\xCE\xB4\xD5\xD2\xB5\xBD\xB4\xC5\xC5\xCC" /* 未找到磁盘 */
#define CN_NO_CLEANABLE "\xC3\xBB\xD3\xD0\xBF\xC9\xC7\xE5\xC0\xED\xB5\xC4\xB4\xC5\xC5\xCC" /* 没有可清理的磁盘 */
#define CN_NO_SELECT    "\xCE\xB4\xD1\xA1\xD4\xF1\xB4\xC5\xC5\xCC" /* 未选择磁盘 */
#define CN_DRIVER_INST  "\xC7\xFD\xB6\xAF\xD2\xD1\xB0\xB2\xD7\xB0" /* 驱动已安装 */
#define CN_DRIVER_INJ   "\xC7\xFD\xB6\xAF\xD2\xD1\xD7\xA2\xC8\xEB" /* 驱动已注入 */
#define CN_REBOOT_RETRY "\xD6\xD8\xC6\xF4\x46\x69\x72\x50\x45\xBA\xF3\xD6\xD8\xCA\xD4" /* 重启FirPE后重试 */
#define CN_NO_DISK_HINT "\xCE\xB4\xD5\xD2\xB5\xBD\xB4\xC5\xC5\xCC\xA3\xAC\xB3\xA2\xCA\xD4\xBD\xAB\xC7\xFD\xB6\xAF\xB7\xC5\xC8\xEB\x64\x72\x69\x76\x65\x72\x73\xCE\xC4\xBC\xFE\xBC\xD0\xBB\xF2\xD6\xD8\xC6\xF4\x46\x69\x72\x50\x45" /* 未找到磁盘，尝试将驱动放入drivers文件夹或重启FirPE */

/* 全局句柄 */
static HINSTANCE g_hInst;
static HWND      g_mainWnd;
HWND g_logBox;                    /* 公共：AppendLog 追加文本用 */
static HWND      g_listView;
static HWND      g_statusBar;
static HWND      g_cleanBtn;
static HFONT     g_uiFont;
static HFONT     g_logFont;   /* 日志框字体：优先 SimSun（中文），回退 Fixedsys */
static int       g_lvtest;        /* -lvtest 模式：窗口建好后 dump ListView 文本到 lvtest.txt 并退出 */

/* 全局数据：磁盘列表与清理状态（worker 线程与主线程共享）
 * 线程间约定：g_cleanResult/g_cleanRun 由 worker 线程写完后再
 * PostMessage 通知主线程读取，主线程读取时不存在竞态 */
static DiskInfo   g_disks[32];
static int        g_diskCount;
static int        g_cleaning;         /* 1=清理进行中，锁定 UI */
static int        g_cleanRun;         /* RunClean 返回值：<0 启动失败 */
static CleanResult g_cleanResult;
static int        g_cleanNums[32];    /* 本次选中要清理的盘号 */
static int        g_cleanNumCount;

/* 驱动自愈状态：g_selfHealResult 由 worker 线程写完后再 PostMessage
 * 通知主线程读取，主线程读取时不存在竞态（同 g_cleanResult 约定） */
static int         g_selfHealActive;   /* 1=自愈线程运行中 */
static int         g_selfHealTried;    /* 1=本次会话已尝试过自愈（防 0 盘循环重试） */
static DriverSelfHealResult g_selfHealResult;

/* U 盘日志目录缓存：首次探测成功即缓存，后续 AppendLog 直接用
 * （避免每次写日志都做盘符扫描+目录检查）；探测失败不缓存，
 * 每次重试（U 盘可能后插入） */
static char g_usbLogDir[MAX_PATH];
static int  g_usbLogDirValid;

/* 会话日志文件名缓存：本次启动的带时间戳日志文件名（如
 * cleanup-20261127-190000.log）。首次写日志时生成，本会话一直用；
 * 下次启动进程重新生成新文件名，天然按会话分文件、便于分辨机器。 */
static char g_sessLogName[64];

/* 取 exe 同目录下的文件名（避免 cwd 变化导致日志位置漂移） */
static void make_exe_dir_path(char* buf, const char* name)
{
    char exe[MAX_PATH];
    DWORD len = GetModuleFileNameA(NULL, exe, MAX_PATH);
    if (len == 0 || len >= MAX_PATH) { strcpy(buf, name); return; }
    char* slash = strrchr(exe, '\\');
    if (slash) *slash = '\0';
    sprintf(buf, "%s\\%s", exe, name);
}

/* 追加一行带时间戳的日志到指定文件 */
static void write_log(const char* path, const char* msg)
{
    SYSTEMTIME st;
    GetLocalTime(&st);
    char line[1024];
    sprintf(line, "[%04lu-%02lu-%02lu %02lu:%02lu:%02lu] %s\r\n",
            (unsigned long)st.wYear, (unsigned long)st.wMonth,
            (unsigned long)st.wDay, (unsigned long)st.wHour,
            (unsigned long)st.wMinute, (unsigned long)st.wSecond, msg);
    /* 二进制追加："a" 文本模式会把行尾 \n 再转成 \r\n，导致每行 \r\r\n
     * 双回车（实测 cleanup.log 尾部 0D 0D 0A）；"ab" 保持 \r\n 原样 */
    FILE* f = fopen(path, "ab");
    if (f) { fputs(line, f); fclose(f); }
}

/* 启动打点：写 exe 同目录 startup.log */
void BootLog(const char* msg)
{
    char path[MAX_PATH];
    make_exe_dir_path(path, "startup.log");
    write_log(path, msg);
}



/* 生成 ASCII 过滤副本：>0x7F 的字节替换为 '?'。
 * FirPE 无中文字体，UI 日志框直接显示 GBK 中文会乱码；
 * 日志文件保留原始字节（cleanup.log 写原文，便于排查命令真实输出）。 */
static void ascii_filter(const char* in, char* out, size_t cap)
{
    size_t i, j = 0;
    if (cap == 0) return;
    for (i = 0; in[i] && j + 1 < cap; i++) {
        unsigned char c = (unsigned char)in[i];
        out[j++] = (c > 0x7F) ? '?' : (char)c;
    }
    out[j] = '\0';
}

/* 中文 diskpart/pnputil 输出的 GBK 字节序列 → 英文译文。
 * （字节值已用 .NET GBK 936 实测核对，见各注释。）
 * 这些短语是日志框里最常见的乱码来源；命中则整体替换为英文，
 * 未知中文保留为 '?'（由 ascii_filter 兜底），保证日志框全英文可读。 */
static const struct { const char* gbk; const char* en; } GBK_TRANSLATE[] = {
    /* pnputil / diskpart 输出短语（字节值已用 .NET GBK 936 实测核对）。
     * 注意表内按字节长度从长到短排列（gbk_translate 依次尝试，先命中长的）。 */
    { "\xD2\xD1\xB3\xC9\xB9\xA6\xCC\xED\xBC\xD3\xC7\xFD\xB6\xAF\xB3\xCC\xD0\xF2\xB3\xCC\xD0\xF2\xB0\xFC", "driver package added successfully" }, /* 已成功添加驱动程序程序包 */
    { "\xD0\xE9\xC4\xE2\xB4\xC5\xC5\xCC\xB7\xFE\xCE\xF1\xB4\xED\xCE\xF3", "virtual disk service error" }, /* 虚拟磁盘服务错误 */
    { "\xC9\xE8\xB1\xB8\xC9\xCF\xB5\xC4\xC7\xFD\xB6\xAF\xB3\xCC\xD0\xF2\xB0\xFC\xCA\xC7\xD7\xEE\xD0\xC2\xB5\xC4", "driver package on device is up to date" }, /* 设备上的驱动程序包是最新的 */
    { "\xC7\xFD\xB6\xAF\xB3\xCC\xD0\xF2\xB0\xFC\xD2\xD1\xB0\xB2\xD7\xB0\xD4\xDA\xC9\xE8\xB1\xB8\xC9\xCF", "driver package installed on device" }, /* 驱动程序包已安装在设备上 */
    { "\xD5\xFD\xD4\xDA\xCC\xED\xBC\xD3\xC7\xFD\xB6\xAF\xB3\xCC\xD0\xF2\xB0\xFC", "adding driver package" }, /* 正在添加驱动程序包 */
    { "\xD2\xD1\xCC\xED\xBC\xD3\xC7\xFD\xB6\xAF\xB3\xCC\xD0\xF2\xB0\xFC\xCA\xFD", "driver packages added" }, /* 已添加驱动程序包数 */
    { "\xC7\xFD\xB6\xAF\xB3\xCC\xD0\xF2\xB0\xFC\xD7\xDC\xCA\xFD", "driver packages total" }, /* 驱动程序包总数 */
    { "\xB8\xC3\xB4\xC5\xC5\xCC\xD2\xD1\xC1\xAA\xBB\xFA", "this disk is already online" }, /* 该磁盘已联机 */
    { "\xCF\xD6\xD4\xDA\xCA\xC7\xCB\xF9\xD1\xA1\xB4\xC5\xC5\xCC", "is now the selected disk" }, /* 现在是所选磁盘 */
    { "\xCD\xCB\xB3\xF6\x20\x44\x69\x73\x6B\x50\x61\x72\x74", "exiting DiskPart" }, /* 退出 DiskPart */
    { "\xC3\xBB\xD3\xD0\xBF\xC9\xD3\xC3\xB5\xC4\xB6\xD4\xCF\xF3", "no object available" }, /* 没有可用的对象 */
    { "\xD4\xDA\xBC\xC6\xCB\xE3\xBB\xFA\xC9\xCF", "on computer" }, /* 在计算机上 */
    { "\xB7\xA2\xB2\xBC\xC3\xFB\xB3\xC6", "published name" }, /* 发布名称 */
    { "\xBE\xDC\xBE\xF8\xB7\xC3\xCE\xCA", "access denied" }, /* 拒绝访问 */
    { "\xD2\xD1\xB3\xC9\xB9\xA6\xB0\xB2\xD7\xB0", "installed successfully" }, /* 已成功安装 */
    { "\xD2\xD1\xB3\xC9\xB9\xA6\xCC\xED\xBC\xD3", "added successfully" }, /* 已成功添加 */
    { "\xB3\xC9\xB9\xA6\xB5\xD8\xC7\xE5\xB3\xFD", "successfully cleaned" }, /* 成功地清除 */
    { "\xD2\xD1\xB3\xC9\xB9\xA6\xC7\xE5\xB3\xFD", "successfully cleaned" }, /* 已成功清除 */
    { "\xC7\xFD\xB6\xAF\xB3\xCC\xD0\xF2\xB0\xFC", "driver package" }, /* 驱动程序包 */
    { "\xCE\xB4\xC4\xDC\xC7\xE5\xB3\xFD", "could not clean" }, /* 未能清除 */
    { "\xCA\xC7\xD7\xEE\xD0\xC2\xB5\xC4", "is up to date" }, /* 是最新的 */
    { "\xCE\xB4\xC4\xDC", "cannot" }, /* 未能 */
    { "\xCA\xA7\xB0\xDC", "failed" }, /* 失败 */
    { "\xB4\xED\xCE\xF3", "error" }, /* 错误 */
    { "\xBE\xDC\xBE\xF8", "denied" }, /* 拒绝 */
    { "\xCE\xDE\xD0\xA7", "invalid" }, /* 无效 */
    { "\xB2\xCE\xCA\xFD", "parameter" }, /* 参数 */
    { "\xC3\xBB\xD3\xD0\xD5\xD2\xB5\xBD", "not found" }, /* 没有找到 */
    { "\xC6\xF4\xB6\xAF", "started" }, /* 启动 */
    { "\xB0\xE6\xB1\xBE", "version" }, /* 版本 */
    { "\xB4\xC5\xC5\xCC", "disk" }, /* 磁盘 */
    { "\xC1\xAA\xBB\xFA", "online" }, /* 联机 */
    { "\xCD\xD0\xBB\xFA", "offline" }, /* 脱机 */
    { "\xD4\xDA\xCF\xDF", "online" }, /* 在线 */
    { "\xB3\xC9\xB9\xA6", "success" }, /* 成功 */
    { "\xCC\xED\xBC\xD3", "add" }, /* 添加 */
    { "\xC9\xE8\xB1\xB8", "device" }, /* 设备 */
    { "\xC7\xFD\xB6\xAF", "driver" }, /* 驱动 */
    { "\xB0\xFC", "package" }, /* 包 */
    { "\xC5\xCC", "disk" }, /* 盘 */
};

/* 把 GBK 中文短语翻译成英文（未知中文→'?'）。输出始终纯 ASCII。
 * 逐短语从输入首字节起做最长匹配（GBK 两字节对齐，避免把半个汉字
 * 翻译错）；翻译表按字节长度降序排列保证最长优先。 */
static void gbk_translate(const char* in, char* out, size_t cap)
{
    size_t i = 0, j = 0;
    size_t n = sizeof(GBK_TRANSLATE) / sizeof(GBK_TRANSLATE[0]);
    while (in[i] && j + 1 < cap) {
        int matched = 0;
        unsigned int k;
        /* 尝试匹配一个中文短语（含 ASCII 前缀如 "DiskPart "） */
        for (k = 0; k < n; k++) {
            const char* p = in + i;
            const char* q = GBK_TRANSLATE[k].gbk;
            size_t ql = 0;
            while (*q && *p) {
                if (*p != *q) break;
                p++; q++; ql++;
            }
            if (*q == '\0') {   /* 短语完整匹配 */
                size_t el = 0;
                while (GBK_TRANSLATE[k].en[el]) el++;
                if (j + el + 1 >= cap) { j = cap - 1; break; }
                for (el = 0; GBK_TRANSLATE[k].en[el]; el++)
                    out[j++] = GBK_TRANSLATE[k].en[el];
                i += ql;
                matched = 1;
                break;
            }
        }
        if (matched) continue;
        /* 未命中：ASCII 原样保留，GBK 首字节（>=0x80）→ '?' */
        if (j + 2 >= cap) break;
        {
            unsigned char c = (unsigned char)in[i];
            if (c >= 0x80) out[j++] = '?';
            else out[j++] = (char)c;
            i++;
        }
    }
    out[j] = '\0';
}

/* 探测 U 盘上的 FirPE\Log 目录；不存在则自动创建（复用 driver.c FindFirpeSubDir
 * 的盘符扫描模式：先 REMOVABLE 后 FIXED，跳过 RAMDISK/CDROM 等）。
 * 返回 1 成功（out 收目录完整路径），0 失败（无可写盘）。 */
static int FindFirpeLogDir(char* out, int outLen)
{
    return FindFirpeSubDir("Log", out, outLen);
}

/* 运行日志：UI 日志框 + 日志文件
 * 日志文件优先级（文件名带本次启动时间戳，按会话分文件）：
 *   1) U盘\FirPE\Log\cleanup-YYYYMMDD-HHMMSS.log（FirPE\Log 不存在则
 *      自动创建；成功路径缓存，首次探测失败则每次重试，U 盘可能后插入）
 *   2) 回退 %TEMP%\FirpeCleaner\cleanup-YYYYMMDD-HHMMSS.log
 *   3) 再回退 exe 同目录 cleanup-YYYYMMDD-HHMMSS.log
 * 每次启动生成新时间戳文件名（进程内缓存），旧文件保留，便于分辨机器。 */
void AppendLog(const char* line)
{
    char path[MAX_PATH], tmp[MAX_PATH];

    /* 本次会话的日志文件名（首次调用时按当前时间生成） */
    if (!g_sessLogName[0]) {
        SYSTEMTIME st;
        GetLocalTime(&st);
        sprintf(g_sessLogName,
                "cleanup-%04lu%02lu%02lu-%02lu%02lu%02lu.log",
                (unsigned long)st.wYear, (unsigned long)st.wMonth,
                (unsigned long)st.wDay, (unsigned long)st.wHour,
                (unsigned long)st.wMinute, (unsigned long)st.wSecond);
    }

    if (g_usbLogDirValid) {
        sprintf(path, "%s\\%s", g_usbLogDir, g_sessLogName);
    } else if (FindFirpeLogDir(g_usbLogDir, sizeof(g_usbLogDir))) {
        g_usbLogDirValid = 1;
        sprintf(path, "%s\\%s", g_usbLogDir, g_sessLogName);
    } else if (GetTempPathA(MAX_PATH, tmp) && tmp[0]) {
        char dir[MAX_PATH];
        sprintf(dir, "%sFirpeCleaner", tmp);      /* GetTempPathA 末尾带反斜杠 */
        CreateDirectoryA(dir, NULL);              /* 目录已存在则忽略错误 */
        sprintf(path, "%s\\%s", dir, g_sessLogName);
        FILE* f = fopen(path, "a");
        if (f) { fclose(f); }
        else { make_exe_dir_path(path, g_sessLogName); }
    } else {
        make_exe_dir_path(path, g_sessLogName);
    }
    write_log(path, line);                        /* 文件保留原文（含 GBK 中文） */

    /* UI：日志框优先用宋体 SimSun（见 CreateControls），直接显示原文——
     * diskpart/pnputil 的中文（GBK）输出正常渲染，与弹窗一致（FirPE 中文
     * 版必有宋体，零体积不打包字体文件）。若 SimSun 不可用（g_logFont 回退
     * 为 Fixedsys 位图字体、无中文字形），此时才用 gbk_translate 把已知
     * 中文短语翻译成英文兜底，保证日志框仍可读。 */
    if (g_logBox) {
        char buf[1024];
        if (g_logFont == (HFONT)GetStockObject(SYSTEM_FIXED_FONT))
            gbk_translate(line, buf, sizeof(buf));
        else {
            size_t n = strlen(line);
            if (n > sizeof(buf) - 3) n = sizeof(buf) - 3;
            memcpy(buf, line, n);
            buf[n] = '\0';
        }
        buf[sizeof(buf) - 3] = '\0';              /* 保证 \r\n 与 NUL 容得下 */
        strcat(buf, "\r\n");
        SendMessageA(g_logBox, EM_SETSEL, (WPARAM)-1, (LPARAM)-1);
        SendMessageA(g_logBox, EM_REPLACESEL, TRUE, (LPARAM)buf);
    }
}

/* 大小写不敏感的 "already online" 子串检测（-parsefake 验证用；
 * find_sub 是 diskpart.c 的 static 函数，main.c 不可见，故本地实现） */
static int line_has_already_online(const char* line)
{
    static const char needle[] = "already online";
    const char* p;
    for (p = line; *p; p++) {
        const char* q = needle;
        const char* s = p;
        while (*q) {
            char a = *s, b = *q;
            if (!a) return 0;
            if (a >= 'A' && a <= 'Z') a = (char)(a + ('a' - 'A'));
            if (b >= 'A' && b <= 'Z') b = (char)(b + ('a' - 'A'));
            if (a != b) break;
            s++; q++;
        }
        if (!*q) return 1;
    }
    return 0;
}

/* 分块参数：AppendRawOutput 每块 ≤900 字节（日志行缓冲 1024，留时间戳余量） */
#define RAW_CHUNK_MAX 900

/* 统计分块数/最长块（-parsefake 验证用；与 AppendRawOutput 同一切块逻辑） */
static void raw_chunk_stats(const char* raw, int* chunks, int* maxLen)
{
    int n = 0, mx = 0;
    if (!raw) { *chunks = 0; *maxLen = 0; return; }
    while (*raw) {
        int len = 0;
        while (*raw && len < RAW_CHUNK_MAX) { raw++; len++; }
        n++;
        if (len > mx) mx = len;
    }
    *chunks = n;
    *maxLen = mx;
}

/* 把 diskpart 原始输出分块追加日志：每块 ≤900 字节，防日志行缓冲溢出。
 * 原文写日志文件（GBK 保留），UI 框经 ascii_filter 过滤成 '?'。 */
static void AppendRawOutput(const char* raw)
{
    char chunk[RAW_CHUNK_MAX + 1];
    int n;
    if (!raw || !raw[0]) return;
    while (*raw) {
        n = 0;
        while (*raw && n < RAW_CHUNK_MAX) chunk[n++] = *raw++;
        chunk[n] = '\0';
        AppendLog(chunk);
    }
}

/* 统一布局：WM_CREATE 与 WM_SIZE 共用
 * 客户区 900x580 时的参考值：
 *   ListView (10,10)-(890,400)、状态行 (10,410)-(780,440)、
 *   按钮 (800,410)-(890,440)、日志框 (10,450)-(890,570) */
static void LayoutControls(HWND hwnd)
{
    RECT rc;
    GetClientRect(hwnd, &rc);
    int W = rc.right - rc.left;
    int H = rc.bottom - rc.top;

    /* 日志框：底部 10px 边距，固定高 120 */
    int y_log = H - 130;
    /* 按钮 + 状态文本行：日志框上方 10px，高 30 */
    int y_mid = y_log - 40;

    MoveWindow(g_listView,  10, 10, W - 20, y_mid - 20, TRUE);
    MoveWindow(g_statusBar, 10, y_mid, W - 120, 30, TRUE);
    MoveWindow(g_cleanBtn,  W - 100, y_mid, 90, 30, TRUE);
    MoveWindow(g_logBox,    10, y_log, W - 20, 120, TRUE);
}

/* 创建子控件并完成 ListView 列定义 */
static void CreateControls(HWND hwnd)
{
    g_listView = CreateWindowExA(0, WC_LISTVIEWA, "Disks",
        WS_CHILD | WS_VISIBLE | LVS_REPORT,
        0, 0, 0, 0, hwnd, (HMENU)IDC_LISTVIEW, g_hInst, NULL);
    if (!g_listView) BootLog("M2F ListView failed");
    g_statusBar = CreateWindowExA(0, "STATIC", "Ready",
        WS_CHILD | WS_VISIBLE | SS_LEFT,
        0, 0, 0, 0, hwnd, (HMENU)IDC_STATUS, g_hInst, NULL);
    if (!g_statusBar) BootLog("M2F StatusText failed");
    g_cleanBtn = CreateWindowExA(0, "BUTTON", CN_CLEAR,
        WS_CHILD | WS_VISIBLE | BS_PUSHBUTTON,
        0, 0, 0, 0, hwnd, (HMENU)IDC_CLEAN, g_hInst, NULL);
    if (!g_cleanBtn) BootLog("M2F CleanBtn failed");
    g_logBox = CreateWindowExA(0, "EDIT", "",
        WS_CHILD | WS_VISIBLE | ES_MULTILINE | ES_READONLY | ES_AUTOVSCROLL
        | WS_VSCROLL | WS_HSCROLL,
        0, 0, 0, 0, hwnd, (HMENU)IDC_LOGBOX, g_hInst, NULL);
    if (!g_logBox) BootLog("M2F LogBox failed");

    /* 控件字体：分两套。
     * 1) 列表主体（行内容为 ASCII PhysicalDriveN 等）：Fixedsys 等宽位图
     *    字体，ROM 内置、英文渲染 100% 不乱码。
     * 2) 列头/按钮/状态栏/日志框：中文文案，必须用宋体 g_logFont
     *    （CreateFontA 逻辑字体，FirPE 中文版必有，零体积不打包字体文件）；
     *    SimSun 不可用才回退 Fixedsys（此时中文显示为乱码的风险由
     *    gbk_translate 翻译表兜底日志框为英文）。 */
    g_uiFont = (HFONT)GetStockObject(SYSTEM_FIXED_FONT);
    g_logFont = CreateFontA(14, 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE,
                            DEFAULT_CHARSET, OUT_DEFAULT_PRECIS,
                            CLIP_DEFAULT_PRECIS, DEFAULT_QUALITY,
                            DEFAULT_PITCH | FF_DONTCARE, "SimSun");
    if (!g_logFont)
        g_logFont = (HFONT)GetStockObject(SYSTEM_FIXED_FONT);

    /* ListView 扩展风格：网格线 + 复选框 + 整行选中 */
    SendMessageA(g_listView, LVM_SETEXTENDEDLISTVIEWSTYLE, 0,
        (LPARAM)(LVS_EX_GRIDLINES | LVS_EX_CHECKBOXES | LVS_EX_FULLROWSELECT));

    /* 7 列标题（中文，GBK 字节转义——LVM_INSERTCOLUMNA 是 ANSI 消息，
     * 源码 UTF-8 的中文不能直接传，必须用 GBK 字节串，与 diskpart.c
     * 的 CN_* 常量同风格；字节值已用 .NET GBK 936 实测）：
     *   硬盘=D3B2C5CC 型号=D0CDBAC5 总线=D7DCCFDF
     *   总容量GB=D7DCC8DDC1BF 4742 剩余GB=CA53D3E04742
     *   状态=D7B4CCAC 盘状态=C5CC D7B4CCAC
     * 列宽：硬盘列 150（容纳 "PhysicalDrive10" 完整显示），型号 130。 */
    static const char* const colTitles[7] = {
        "\xD3\xB2\xC5\xCC",                        /* 硬盘 */
        "\xD0\xCD\xBA\xC5",                        /* 型号 */
        "\xD7\xDC\xCF\xDF",                        /* 总线 */
        "\xD7\xDC\xC8\xDD\xC1\xBF\x47\x42",        /* 总容量GB */
        "\xCA\xA3\xD3\xE0\x47\x42",                /* 剩余GB */
        "\xD7\xB4\xCC\xAC",                        /* 状态 */
        "\xC5\xCC\xD7\xB4\xCC\xAC",                /* 盘状态 */
    };
    static const int colWidths[7] = { 150, 130, 70, 80, 80, 160, 70 };
    LVCOLUMNA lc;
    int i;
    for (i = 0; i < 7; i++) {
        memset(&lc, 0, sizeof(lc));
        lc.mask     = LVCF_TEXT | LVCF_WIDTH | LVCF_SUBITEM;
        lc.fmt      = LVCFMT_LEFT;
        lc.cx       = colWidths[i];
        lc.pszText  = colTitles[i];
        lc.iSubItem = i;
        SendMessageA(g_listView, LVM_INSERTCOLUMNA, (WPARAM)i, (LPARAM)&lc);
    }

    /* 字体设置在插列完成之后（关键）：列已存在时给 ListView 发 WM_SETFONT
     * 会把字体正确传播给内部列头（SysHeader32）。列头/按钮/状态栏标题是
     * 中文，必须用宋体 g_logFont 渲染（Fixedsys 位图字体无中文字形）；
     * 行内容为 ASCII（PhysicalDriveN 等），ListView 主体用 Fixedsys g_uiFont
     * 保持等宽整齐。早期版本在插列之前设置字体、且单独给列头发
     * WM_SETFONT，列头字体反而被 LVM_INSERTCOLUMN 的重排重置，回落到系统
     * 的 icon-title 字体，于是行内容正常而列头乱码。这里在插列后统一设置，
     * 再对列头显式再设一次（双保险）。 */
    SendMessageA(g_listView,  WM_SETFONT, (WPARAM)g_uiFont, TRUE);
    SendMessageA(g_statusBar, WM_SETFONT, (WPARAM)g_logFont, TRUE);
    SendMessageA(g_cleanBtn,  WM_SETFONT, (WPARAM)g_logFont, TRUE);
    SendMessageA(g_logBox,    WM_SETFONT, (WPARAM)g_logFont, TRUE);
    {
        HWND hdr = (HWND)SendMessageA(g_listView, LVM_GETHEADER, 0, 0);
        if (hdr)
            SendMessageA(hdr, WM_SETFONT, (WPARAM)g_logFont, TRUE);
    }

    /* 显式颜色：FirPE 无视觉样式时 ListView 文字/背景可能渲染异常，
     * 强制 ListView 黑字白底（LVM_SETTEXTCOLOR=0x1024、LVM_SETBKCOLOR=0x1001
     * 为官方值，本机实测可读回，见 patches.h）。
     * 列头颜色：HDM_SETTEXTCOLOR 实测（本机 comctl32 5.82 无 manifest，与
     * FirPE 一致）仅 0x1208 可存储/读回文本色，但对默认列头渲染无可见效果
     * （像素级验证设红后无红像素），列头文字默认即系统黑——发送黑字仅为
     * 兜底、无害。不存在可用的背景色消息（0x120A/0x120B/0x120C 传 COLORREF
     * 实测崩溃——它们是 HDM_INSERTITEMW/GETITEMW/SETITEMW 指针消息），
     * 列头背景保持系统默认，黑字在系统背景上可见。 */
    SendMessageA(g_listView, LVM_SETTEXTCOLOR, 0, (LPARAM)RGB(0, 0, 0));
    SendMessageA(g_listView, LVM_SETBKCOLOR,   0, (LPARAM)RGB(255, 255, 255));
    {
        HWND hdr = (HWND)SendMessageA(g_listView, LVM_GETHEADER, 0, 0);
        if (hdr) {
            SendMessageA(hdr, HDM_SETTEXTCOLOR, 0, (LPARAM)RGB(0, 0, 0));
        }
    }

    LayoutControls(hwnd);
    AppendLog("UI initialized");
}

/* ============ 磁盘列表填充与清理流程 ============ */

/* 设置 ListView 某行某列的子列文本 */
static void set_subitem(int row, int col, const char* text)
{
    LVITEMA item;
    memset(&item, 0, sizeof(item));
    item.mask     = LVIF_TEXT;
    item.iItem    = row;
    item.iSubItem = col;
    item.pszText  = (char*)text;
    SendMessageA(g_listView, LVM_SETITEMTEXTA, (WPARAM)row, (LPARAM)&item);
}

/* 行 i 是否勾选（checkbox 状态图索引 == 2 为勾选） */
static int IsItemChecked(int i)
{
    LRESULT state = SendMessageA(g_listView, LVM_GETITEMSTATE,
                                 (WPARAM)i, (LPARAM)LVIS_STATEIMAGEMASK);
    return (int)((state >> 12) == 2);
}

/* 统计可清理盘数（未排除） */
static int count_cleanable(void)
{
    int i, n = 0;
    for (i = 0; i < g_diskCount; i++)
        if (!g_disks[i].IsExcluded) n++;
    return n;
}

/* ============ 驱动自愈（0 盘/0 可清时自动尝试注入 RAID 卡驱动） ============ */

/* worker 线程：执行驱动自愈，完成后通知主线程（g_selfHealResult 供主线程读取）。
 * 用 FindWindowA 兜底取窗口句柄：自愈可能在 WM_CREATE 期间启动，
 * 此时 g_mainWnd 尚未赋值（CreateWindowExA 尚未返回） */
static DWORD WINAPI WorkerSelfHeal(LPVOID p)
{
    HWND hw;
    (void)p;
    g_selfHealResult = SelfHealDriver();
    hw = g_mainWnd;
    if (!hw) hw = FindWindowA(APP_CLASS, NULL);
    if (hw) PostMessage(hw, WM_APP_DRIVER_DONE, 0, 0);
    return 0;
}

/* 0 盘/0 可清时启动自愈后台线程（pnputil/sc 可能耗时几十秒，不能阻塞 UI；
 * 已尝试过则不再启动，防自愈后仍 0 盘导致循环重试） */
static void StartDriverSelfHeal(void)
{
    HANDLE h;
    if (g_selfHealActive || g_selfHealTried) return;
    AppendLog("0 cleanable. Checking for RAID controller driver...");
    BootLog("D0 self-heal thread start");
    if (!HasLinkdataDevice()) {
        /* 只匹配 Linkdata（VEN_1ff2）硬件：非目标硬件绝不注入，本会话不再重试 */
        AppendLog("No Linkdata (VEN_1ff2) device found. Driver injection skipped.");
        BootLog("D0 skip: no Linkdata device");
        g_selfHealTried = 1;
        return;
    }
    g_selfHealActive = 1;
    h = CreateThread(NULL, 0, WorkerSelfHeal, NULL, 0, NULL);
    if (!h) {
        g_selfHealActive = 0;
        g_selfHealTried = 1;
        AppendLog("Failed to start driver self-heal thread.");
        BootLog("D0F thread create failed");
        return;
    }
    CloseHandle(h);   /* 线程句柄不等待，直接释放 */
}

/* 枚举磁盘并填充 ListView：可清盘默认勾选，排除盘不勾选。
 * 空状态（无盘/全排除）：状态文本提示 + Clean 按钮禁用 */
static void PopulateDiskList(void)
{
    char buf[64];
    int i, cleanable = 0;

    SendMessageA(g_listView, LVM_DELETEALLITEMS, 0, 0);
    g_diskCount = EnumerateDisks(g_disks, 32);
    if (g_diskCount < 0) g_diskCount = 0;   /* 失败/无盘一律按 0 处理 */

    /* 状态填充：diskpart list disk 解析每块盘 online/offline（diskpart 不可用
     * 时保持 -1 unknown，State 列显示 "-"） */
    {
        int omap[32];
        int oi;
        for (oi = 0; oi < g_diskCount; oi++) g_disks[oi].Online = -1;  /* 默认 unknown */
        if (GetDiskOnlineMap(omap, 32) == 0) {
            char db[512];
            int off = 0;
            for (oi = 0; oi < g_diskCount; oi++) {
                int num = g_disks[oi].Number;
                if (num >= 0 && num < 32) g_disks[oi].Online = omap[num];
            }
            off += sprintf(db + off, "[D] online map:");
            for (oi = 0; oi < 32 && off < (int)sizeof(db) - 16; oi++) {
                if (omap[oi] < 0) continue;
                off += sprintf(db + off, " disk%d=%d", oi, omap[oi]);
            }
            BootLog(db);
        }
    }

    if (g_diskCount == 0) {
        SetWindowTextA(g_statusBar, CN_NO_DISK);
        EnableWindow(g_cleanBtn, FALSE);
        BootLog("W0 enumerate done, 0 cleanable");
        StartDriverSelfHeal();   /* 0 盘 → 后台尝试注入 RAID 卡驱动 */
        return;
    }

    for (i = 0; i < g_diskCount; i++) {
        LVITEMA item;

        /* 插入行：主列文本 PhysicalDriveN，lParam=行索引 */
        memset(&item, 0, sizeof(item));
        item.mask     = LVIF_TEXT | LVIF_PARAM;
        item.iItem    = i;
        item.iSubItem = 0;
        item.lParam   = (LPARAM)i;
        sprintf(buf, "PhysicalDrive%d", g_disks[i].Number);
        item.pszText  = buf;
        SendMessageA(g_listView, LVM_INSERTITEMA, (WPARAM)i, (LPARAM)&item);

        /* 子列：Model / Bus / Size GB / Free GB / Status */
        set_subitem(i, 1, g_disks[i].Model);
        set_subitem(i, 2, g_disks[i].Bus);
        sprintf(buf, "%d", (int)g_disks[i].SizeGB);
        set_subitem(i, 3, buf);
        if (g_disks[i].FreeGB < 0) {
            set_subitem(i, 4, "-");
        } else {
            sprintf(buf, "%d", (int)g_disks[i].FreeGB);
            set_subitem(i, 4, buf);
        }
        set_subitem(i, 5, g_disks[i].Status);
        /* State 列：Online / Offline / -（unknown） */
        if (g_disks[i].Online == 1)      set_subitem(i, 6, "Online");
        else if (g_disks[i].Online == 0) set_subitem(i, 6, "Offline");
        else                             set_subitem(i, 6, "-");

        /* 默认全选：仅可清盘勾选（排除盘不勾；安全兜底见 OnCleanClicked） */
        if (!g_disks[i].IsExcluded) {
            LVITEMA st;
            memset(&st, 0, sizeof(st));
            st.mask      = LVIF_STATE;
            st.stateMask = LVIS_STATEIMAGEMASK;
            st.state     = INDEXTOSTATEIMAGEMASK(2);
            SendMessageA(g_listView, LVM_SETITEMSTATE, (WPARAM)i, (LPARAM)&st);
            cleanable++;
        }
    }

    if (cleanable == 0) {
        SetWindowTextA(g_statusBar, CN_NO_CLEANABLE);
        EnableWindow(g_cleanBtn, FALSE);
        StartDriverSelfHeal();   /* 0 可清 → 后台尝试注入 RAID 卡驱动 */
    } else {
        /* "N 个磁盘就绪"（GBK：N 数字 ASCII + 个磁盘就绪） */
        sprintf(buf, "%d \xB8\xF6\xB4\xC5\xC5\xCC\xBE\xCD\xD0\xF7", cleanable);
        SetWindowTextA(g_statusBar, buf);
        EnableWindow(g_cleanBtn, TRUE);
    }
    sprintf(buf, "W0 enumerate done, %d cleanable", cleanable);
    BootLog(buf);
}

/* worker 线程：执行 RunClean，完成后通知主线程（g_cleanResult 供主线程读取） */
static DWORD WINAPI WorkerClean(LPVOID p)
{
    (void)p;
    g_cleanRun = RunClean(g_cleanNums, g_cleanNumCount, &g_cleanResult);
    PostMessage(g_mainWnd, WM_APP_CLEAN_DONE, 0, 0);
    return 0;
}

/* Clean 按钮：收集选中盘 → 二次确认弹窗 → 锁 UI → 启动 worker 线程 */
static void OnCleanClicked(void)
{
    char buf[512];
    int i;

    /* 1) 收集：仅 !IsExcluded 且勾选的行（即使 UI 勾了排除盘也不会被清理） */
    g_cleanNumCount = 0;
    for (i = 0; i < g_diskCount; i++) {
        if (!g_disks[i].IsExcluded && IsItemChecked(i))
            g_cleanNums[g_cleanNumCount++] = g_disks[i].Number;
    }
    if (g_cleanNumCount == 0) {
        SetWindowTextA(g_statusBar, CN_NO_SELECT);
        AppendLog("No disk selected.");
        return;
    }

    /* 2) 二次确认：逐盘列出（PhysicalDriveN (Model, N GB)），警告 + Yes/No */
    {
        char msg[2048];
        int off = 0;
        off += sprintf(msg + off,
            "WARNING: this will permanently erase ALL data on the following disk(s):\n\n");
        for (i = 0; i < g_cleanNumCount; i++) {
            int j;
            for (j = 0; j < g_diskCount; j++)
                if (g_disks[j].Number == g_cleanNums[i]) break;
            if (j == g_diskCount) continue;          /* 理论上不会发生，兜底跳过 */
            if (off < 1800) {                        /* 防 2048 缓冲溢出（单条最长约 160 字节） */
                if (g_disks[j].Model[0])
                    off += sprintf(msg + off, "PhysicalDrive%d (%s, %d GB)\n",
                                   g_cleanNums[i], g_disks[j].Model,
                                   (int)g_disks[j].SizeGB);
                else
                    off += sprintf(msg + off, "PhysicalDrive%d (%d GB)\n",
                                   g_cleanNums[i], (int)g_disks[j].SizeGB);
            }
        }
        off += sprintf(msg + off, "\nContinue?");
        if (MessageBoxA(g_mainWnd, msg, "FirPE Disk Cleaner - Confirm",
                        MB_YESNO | MB_ICONWARNING | MB_DEFBUTTON2) != IDYES) {
            AppendLog("Clean cancelled by user.");
            return;
        }
    }

    /* 3) 打点 + 锁 UI + 启动 worker 线程 */
    sprintf(buf, "C1 confirmed, %d disks", g_cleanNumCount);
    BootLog(buf);
    g_cleaning = 1;
    EnableWindow(g_cleanBtn, FALSE);
    EnableWindow(g_listView, FALSE);
    SetWindowTextA(g_statusBar, CN_CLEANING);
    sprintf(buf, "Clean start:");
    for (i = 0; i < g_cleanNumCount; i++) {
        size_t used = strlen(buf);
        if (used < sizeof(buf) - 20)   /* 防 512 缓冲溢出（单条最长约 18 字节） */
            sprintf(buf + used, " PhysicalDrive%d", g_cleanNums[i]);
    }
    AppendLog(buf);

    BootLog("C2 clean thread start");
    {
        HANDLE h = CreateThread(NULL, 0, WorkerClean, NULL, 0, NULL);
        if (!h) {
            g_cleaning = 0;
            EnableWindow(g_cleanBtn, TRUE);
            EnableWindow(g_listView, TRUE);
            SetWindowTextA(g_statusBar, CN_FAILED);
            AppendLog("Failed to start worker thread.");
            BootLog("C2F thread create failed");
            return;
        }
        CloseHandle(h);   /* 线程句柄不等待，直接释放 */
    }
}

/* 清理完成（WM_APP_CLEAN_DONE）：恢复 UI 并按结果更新状态/日志/弹窗 */
static void OnCleanDone(void)
{
    char buf[512];
    int i;

    g_cleaning = 0;
    EnableWindow(g_listView, TRUE);
    EnableWindow(g_cleanBtn, count_cleanable() > 0 ? TRUE : FALSE);

    if (g_cleanRun < 0) {
        SetWindowTextA(g_statusBar, CN_FAILED);
        AppendLog("Failed to start diskpart.");
    } else if (g_cleanResult.Success) {
        SetWindowTextA(g_statusBar, CN_DONE);
        sprintf(buf, "Clean finished: %d disk(s) cleaned.", g_cleanResult.CleanedCount);
        AppendLog(buf);
        /* 成功弹窗（中文：磁盘已清理，准备重装系统——GBK 字节） */
        MessageBoxA(g_mainWnd,
            "\xB4\xC5\xC5\xCC\xD2\xD1\xC7\xE5\xC0\xED\xA3\xAC\xD7\xBC\xB1\xB8\xD6\xD8\xD7\xB0\xCF\xB5\xCD\xB3",
            "FirPE Disk Cleaner", MB_OK | MB_ICONINFORMATION);
    } else {
        SetWindowTextA(g_statusBar, CN_FAILED);
        for (i = 0; i < g_cleanResult.FailureCount; i++) {
            sprintf(buf, "  %s", g_cleanResult.Failures[i]);
            AppendLog(buf);   /* 日志文件写原文，保留 diskpart 真实输出供排查 */
        }
        /* 无条件附上 diskpart 原始输出，排查完整失败原因（历史 bug：v11 仅
         * FailureCount==0 时写 RawOutput，导致 FailureCount>0（如抓到"虚拟
         * 磁盘服务错误"）时，其后续关键错误行（如"没有可用的对象/请确认
         * 磁盘在线"）全部丢失）。原文写日志文件（GBK 保留），UI 框经
         * ascii_filter 过滤成 '?'；分块 ≤900 字节防日志行缓冲溢出。 */
        if (g_cleanResult.RawOutput[0]) {
            AppendLog("--- diskpart raw output ---");
            AppendRawOutput(g_cleanResult.RawOutput);
        }
        /* 弹窗不拼接 Failures：中文输出经翻译后仍可能有 '?'，无排查价值。
         * 改为固定提示 + 指引日志文件位置（带本次启动时间戳）。
         * 中文：磁盘清理失败，详见带时间戳的日志文件 */
        MessageBoxA(g_mainWnd,
            "\xB4\xC5\xC5\xCC\xC7\xE5\xC0\xED\xCA\xA7\xB0\xDC\xA3\xAC\xCF\xEA\xBC\xE4\xC7\xE9\xBF\xB4\xC8\xD5\xD6\xBE\xCE\xC4\xBC\xFE\xA1\xA3\n"
            "\xC8\xD5\xD6\xBE\xCE\xC4\xBC\xFE\xCE\xBB\xD6\xC3\xA3\xBA\xC4\xFA\xC5\xCC\x46\x69\x72\x50\x45\x5C\x4C\x6F\x67\x5C\x63\x6C\x65\x61\x6E\x75\x70\x2D\x59\x59\x59\x59\x4D\x4D\x44\x44\x2D\x48\x48\x4D\x4D\x53\x53\x2E\x6C\x6F\x67",
            "Clean failed", MB_OK | MB_ICONERROR);
    }
    BootLog("C3 clean done");
}

/* 驱动自愈完成（WM_APP_DRIVER_DONE）：
 * 自愈完成后无条件重新枚举（驱动可能已加载成功，列表应刷新），
 * 再根据枚举结果与自愈状态决定状态栏提示。g_selfHealTried 已置 1，
 * 即使仍 0 盘也不会重入 StartDriverSelfHeal 造成循环。 */
static void OnDriverDone(void)
{
    char buf[512];
    int cleanable;
    g_selfHealActive = 0;
    g_selfHealTried = 1;
    sprintf(buf, "D1 self-heal done, loaded=%d injected=%d testsigning=%d",
            g_selfHealResult.Loaded, g_selfHealResult.InjectedToFirpe,
            g_selfHealResult.TestsigningSet);
    BootLog(buf);
    AppendLog(g_selfHealResult.Detail);
    /* 无条件重新枚举：驱动可能已加载成功，列表应刷新（g_selfHealTried=1 防循环） */
    PopulateDiskList();
    cleanable = count_cleanable();
    if (cleanable > 0) {
        /* 已看到盘，正常状态（PopulateDiskList 已设置状态文本） */
        return;
    }
    /* 仍 0 可清：按自愈结果给提示 */
    if (g_selfHealResult.InjectedToFirpe) {
        /* Detail 形如 "driver injected to X:\FirPE\Drivers, reboot FirPE then rerun"，
         * 直接展示（含具体盘符路径），比笼统提示更有用 */
        SetWindowTextA(g_statusBar, g_selfHealResult.Detail);
    } else if (g_selfHealResult.TestsigningSet) {
        SetWindowTextA(g_statusBar,
            CN_DRIVER_INJ " " CN_REBOOT_RETRY);
    } else {
        SetWindowTextA(g_statusBar, CN_NO_DISK_HINT);
    }
    EnableWindow(g_cleanBtn, FALSE);
}

/* -lvtest 附加验证：comctl32 v6 视觉样式激活检测（uxtheme.dll IsAppThemed）。
 * 有 comctl32 v6 manifest 且系统主题可用时返回 1；无 manifest（v5 行为）返回 0；
 * uxtheme 不可用返回 -1。运行期证据：列头渲染走 v6 视觉样式路径。 */
static int IsAppThemedEx(void)
{
    typedef BOOL (WINAPI* IsAppThemedFn)(void);
    HMODULE h = LoadLibraryA("uxtheme.dll");
    IsAppThemedFn fn;
    int r;
    if (!h) return -1;
    fn = (IsAppThemedFn)(void*)GetProcAddress(h, "IsAppThemed");
    if (!fn) { FreeLibrary(h); return -1; }
    r = fn() ? 1 : 0;
    FreeLibrary(h);
    return r;
}

/* -lvtest：本机 GUI 数据链路验证。窗口创建（WM_CREATE 已同步填充 ListView）后，
 * 在程序自身进程内用 LVM_GETITEMTEXTA 逐格读回文本写入 exe 同目录 lvtest.txt，
 * 然后退出。跨进程读 ListView 文本会因缓冲区跨进程写失败而读到空，
 * 故必须在程序自身进程内 dump（这是本模式存在的原因）。 */
static void DumpListViewToFile(void)
{
    char path[MAX_PATH];
    char buf[256];
    FILE* f;
    HWND hdr;
    int rows, cols, i, j;
    LVITEMA it;

    if (!g_listView) return;
    make_exe_dir_path(path, "lvtest.txt");
    f = fopen(path, "w");
    if (!f) { BootLog("M0F -lvtest cannot open lvtest.txt"); return; }

    rows = (int)SendMessageA(g_listView, LVM_GETITEMCOUNT, 0, 0);
    hdr = (HWND)SendMessageA(g_listView, LVM_GETHEADER, 0, 0);
    cols = hdr ? (int)SendMessageA(hdr, HDM_GETITEMCOUNT, 0, 0) : 0;
    fprintf(f, "rows=%d cols=%d\n", rows, cols);
    /* comctl32 v6 激活证据（manifest 嵌入后 IsAppThemed 应为 1；-1=uxtheme 不可用） */
    fprintf(f, "IsAppThemed=%d\n", IsAppThemedEx());

    /* 列头文字 dump：用 LVM_GETCOLUMNA 读回（实测可靠读回 "Disk" 等列文字）。
     * 不用 HDM_GETITEMW(0x120B)：本机 comctl32 下该消息超量复制相邻内存，
     * 读回全是乱码，仅适合取列数（HDM_GETITEMCOUNT），不适合读文字。
     * 验证 LVCF_TEXT 修复后列标题确实写入（FirPE 看不到列头的回归检查） */
    if (hdr) {
        LVCOLUMNA lca;
        for (j = 0; j < cols; j++) {
            memset(&lca, 0, sizeof(lca));
            lca.mask       = LVCF_TEXT;
            lca.pszText    = buf;
            lca.cchTextMax = sizeof(buf);
            SendMessageA(g_listView, LVM_GETCOLUMNA, (WPARAM)j, (LPARAM)&lca);
            buf[sizeof(buf) - 1] = '\0';
            fprintf(f, "header col %d: \"%s\"\n", j, buf);
        }
    }

    for (i = 0; i < rows; i++) {
        LRESULT st = SendMessageA(g_listView, LVM_GETITEMSTATE,
                                  (WPARAM)i, (LPARAM)LVIS_STATEIMAGEMASK);
        fprintf(f, "row %d checked=%d:", i, (int)((st >> 12) == 2));
        for (j = 0; j < cols; j++) {
            memset(&it, 0, sizeof(it));
            it.mask     = LVIF_TEXT;
            it.iItem    = i;
            it.iSubItem = j;
            it.pszText  = buf;
            it.cchTextMax = sizeof(buf);
            SendMessageA(g_listView, LVM_GETITEMTEXTA, (WPARAM)i, (LPARAM)&it);
            buf[sizeof(buf) - 1] = '\0';
            fprintf(f, " [%d]\"%s\"", j, buf);
        }
        fprintf(f, "\n");
    }
    fclose(f);
    BootLog("M0 lvtest dump done");
}

/* 窗口过程 */
static LRESULT CALLBACK WndProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam)
{
    switch (msg)
    {
    case WM_CREATE:
        CreateControls(hwnd);
        BootLog("M2 controls created");
        BootLog("W0 enumerate start");
        PopulateDiskList();
        return 0;
    case WM_SIZE:
        LayoutControls(hwnd);
        return 0;
    case WM_COMMAND:
        if (LOWORD(wParam) == IDC_CLEAN) {
            if (g_cleaning) return 0;   /* 清理中忽略重复点击 */
            OnCleanClicked();
        }
        return 0;
    case WM_APP_CLEAN_DONE:
        OnCleanDone();
        return 0;
    case WM_APP_DRIVER_DONE:
        OnDriverDone();
        return 0;
    case WM_CLOSE:
        /* 清理进行中关闭可能留下不一致的磁盘状态，需用户二次确认（与 C# 旧版一致） */
        if (g_cleaning) {
            if (MessageBoxA(g_mainWnd,
                            "Cleaning is still in progress. Exiting now may leave disks in an inconsistent state. Exit anyway?",
                            "FirPE Disk Cleaner",
                            MB_YESNO | MB_ICONWARNING | MB_DEFBUTTON2) != IDYES)
                return 0;   /* 用户取消：忽略关闭请求 */
        }
        DestroyWindow(hwnd);
        return 0;
    case WM_DESTROY:
        /* g_uiFont 为 stock 位图字体（GetStockObject），无需 DeleteObject；
         * g_logFont 若创建了 SimSun（非 stock）则释放 */
        if (g_logFont && g_logFont != (HFONT)GetStockObject(SYSTEM_FIXED_FONT))
            DeleteObject(g_logFont);
        g_uiFont = NULL;
        g_logFont = NULL;
        PostQuitMessage(0);
        return 0;
    default:
        return DefWindowProcA(hwnd, msg, wParam, lParam);
    }
}

int WINAPI WinMain(HINSTANCE hInstance, HINSTANCE hPrevInstance, LPSTR lpCmdLine, int nCmdShow)
{
    (void)hPrevInstance;
    g_hInst = hInstance;
    BootLog("M0 enter WinMain");

    /* -auto：自动化验证模式，不建窗口直接退出 */
    if (lpCmdLine && strstr(lpCmdLine, "-auto")) {
        BootLog("M0 auto mode, skip UI");
        return 0;
    }

    /* -list：磁盘枚举验证模式，结果写入 exe 同目录 disks.txt，不建窗口 */
    if (lpCmdLine && strstr(lpCmdLine, "-list")) {
        char path[MAX_PATH];
        DiskInfo disks[64];
        int n, i;
        DWORD err;
        FILE* f;

        make_exe_dir_path(path, "disks.txt");
        n = EnumerateDisks(disks, 64);
        err = GetLastError();   /* 失败时反映最后一次失败 API 的错误码 */
        f = fopen(path, "w");
        if (!f) {
            BootLog("M0F -list cannot open disks.txt");
            return 1;
        }
        if (n < 0) {
            fprintf(f, "ENUM_FAIL: GetLastError=%lu\n", (unsigned long)err);
        } else {
            for (i = 0; i < n; i++) {
                fprintf(f, "%d|%s|%s|%lld|%lld|%s\n",
                        disks[i].Number, disks[i].Model, disks[i].Bus,
                        (long long)disks[i].SizeGB, (long long)disks[i].FreeGB,
                        disks[i].Status);
            }
        }
        fclose(f);
        BootLog("M0 list mode done");
        return 0;
    }

    /* -scripttest：脚本生成与输出解析验证模式（绝不执行真实 diskpart），
     * 结果写入 exe 同目录 script-test.txt / parse-test.txt */
    if (lpCmdLine && strstr(lpCmdLine, "-scripttest")) {
        char path[MAX_PATH];
        FILE* f;
        int disks[2] = { 0, 1 };
        char* script;

        /* 1) BuildScript → script-test.txt */
        make_exe_dir_path(path, "script-test.txt");
        f = fopen(path, "w");
        if (!f) {
            BootLog("M0F -scripttest cannot open script-test.txt");
            return 1;
        }
        script = BuildScript(disks, 2);
        if (script) { fputs(script, f); free(script); }
        fclose(f);

        /* 2) 内置英文示例输出 → ParseOutput → parse-test.txt
         * 示例：盘 0 成功、盘 1 被拒绝，用于验证解析 */
        make_exe_dir_path(path, "parse-test.txt");
        f = fopen(path, "w");
        if (!f) {
            BootLog("M0F -scripttest cannot open parse-test.txt");
            return 1;
        }
        {
            static const char sample[] =
                "Microsoft DiskPart version 10.0.19041.1\n"
                "\n"
                "Disk 0 is now the selected disk.\n"
                "\n"
                "DiskPart successfully cleaned the disk.\n"
                "\n"
                "Disk 1 is now the selected disk.\n"
                "\n"
                "Access is denied.\n"
                "\n"
                "DiskPart has encountered an error: Access is denied. "
                "See the System Event Log for more information.\n";
            CleanResult cr;
            int i;
            ParseOutput(sample, disks, 2, &cr);
            fprintf(f, "CleanedCount=%d\n", cr.CleanedCount);
            fprintf(f, "FailureCount=%d\n", cr.FailureCount);
            fprintf(f, "Success=%d\n", cr.Success);
            for (i = 0; i < cr.FailureCount; i++)
                fprintf(f, "Failure[%d]=%s\n", i, cr.Failures[i]);
        }
        fclose(f);
        BootLog("M0 scripttest mode done");
        return 0;
    }

    /* -parsefake：ParseOutput 中文（GBK）合成输出解析验证模式（修复 3/2，
     * 绝不执行真实 diskpart），结果写 exe 同目录 parse-fake-test.txt。
     * 合成输出含：
     *   1) "已成功添加"（pnputil 中文成功短语，GBK 字节）——不应记为失败
     *   2) "DiskPart 未能清除磁盘。"（中文 clean 失败输出，GBK 字节）——应记为失败
     *   3) "虚拟磁盘服务错误:" + "没有可用的对象."（VDS 失败行 + 后续行，
     *      GBK 字节，对应真实 cleanup.log 的 offline 盘 clean 失败场景）
     *      ——首行含"错误"应记为失败，后续行不应重复计
     *   4) 英文 "successfully cleaned" 成功行——成功计数 +1
     *   5) v13 新增："该磁盘已联机。"（GBK 字节）+ 英文
     *      "Disk 2 is already online."——状态提示，不得计为失败
     * 验证：①成功短语不误报失败；②"未能清除磁盘"被记为失败；
     *   ③VDS 错误行被记为失败且后续行不重复计；
     *   ④"该磁盘已联机"/"already online" 行不被记为失败；
     *   ⑤RawOutput 字段保留全文（RunClean 在 ParseOutput 之后补写，这里用
     *   同一语句序列验证字段容量与截断行为，并确认 ParseOutput 会先清空
     *   整个 out——证明必须在 ParseOutput 之后补写）；
     *   ⑥AppendRawOutput 分块写不越界（每块 ≤900 字节，raw_chunk_stats 验证）。 */
    if (lpCmdLine && strstr(lpCmdLine, "-parsefake")) {
        char path[MAX_PATH];
        FILE* f;
        /* GBK 字节（.NET 936 实测）：已成功添加 = D2D1 B3C9 B9A6 CCED BCD3；
         * 未能清除磁盘 = CEB4 C4DC C7E5 B3FD B4C5 C5CC；
         * 虚拟磁盘服务错误 = D0E9 C4E2 B4C5 C5CC B7FE CEF1 B4ED CEF3；
         * 没有可用的对象 = C3BB D3D0 BFC9 D3C3 B5C4 B6D4 CFF3；
         * 该磁盘已联机 = B8C3 B4C5 C5CC D2D1 C1AA BBFA（注意"该"=B8 C3） */
        static const char sample[] =
            "Microsoft DiskPart version 10.0.19041.1\n"
            "\n"
            "Disk 0 is now the selected disk.\n"
            "\n"
            "DiskPart successfully cleaned the disk.\n"
            "\n"
            "\xD2\xD1\xB3\xC9\xB9\xA6\xCC\xED\xBC\xD3 driver package.\n"   /* 已成功添加 */
            "\n"
            "Disk 1 is now the selected disk.\n"
            "\n"
            "DiskPart \xCE\xB4\xC4\xDC\xC7\xE5\xB3\xFD\xB4\xC5\xC5\xCC.\n"  /* 未能清除磁盘 */
            "\n"
            "\xD0\xE9\xC4\xE2\xB4\xC5\xC5\xCC\xB7\xFE\xCE\xF1\xB4\xED\xCE\xF3:\n"  /* 虚拟磁盘服务错误: */
            "\xC3\xBB\xD3\xD0\xBF\xC9\xD3\xC3\xB5\xC4\xB6\xD4\xCF\xF3.\n"          /* 没有可用的对象. */
            "\n"
            "Disk 2 is already online.\n"
            "\n"
            "\xB8\xC3\xB4\xC5\xC5\xCC\xD2\xD1\xC1\xAA\xBB\xFA.\n"   /* 该磁盘已联机. */
            "\n"
            "DiskPart has encountered an error.\n";
        CleanResult cr;
        int disks[2] = { 0, 1 };
        int i;

        make_exe_dir_path(path, "parse-fake-test.txt");
        f = fopen(path, "w");
        if (!f) {
            BootLog("M0F -parsefake cannot open parse-fake-test.txt");
            return 1;
        }
        ParseOutput(sample, disks, 2, &cr);
        fprintf(f, "CleanedCount=%d\n", cr.CleanedCount);
        fprintf(f, "FailureCount=%d\n", cr.FailureCount);
        fprintf(f, "Success=%d\n", cr.Success);
        for (i = 0; i < cr.FailureCount; i++)
            fprintf(f, "Failure[%d]=%s\n", i, cr.Failures[i]);
        {
            int vdsCaught = 0, j;
            for (j = 0; j < cr.FailureCount; j++)
                if (strstr(cr.Failures[j], "\xB4\xED\xCE\xF3") != NULL) {  /* 含"错误" */
                    vdsCaught = 1;
                    break;
                }
            fprintf(f, "Vds_line_caught=%d\n", vdsCaught);
        }
        /* v13：合成输出含 "该磁盘已联机。"（GBK）与 "Disk 2 is already online."
         * 两行，均不得被记入 Failures */
        {
            int j, caught = 0;
            for (j = 0; j < cr.FailureCount; j++)
                if (strstr(cr.Failures[j], "\xB8\xC3\xB4\xC5\xC5\xCC\xD2\xD1\xC1\xAA\xBB\xFA") != NULL
                    || line_has_already_online(cr.Failures[j])) {
                    caught = 1;
                    break;
                }
            fprintf(f, "Already_online_not_caught=%d\n", caught ? 0 : 1);
        }
        fprintf(f, "RawOutput_after_parse_empty=%d\n", cr.RawOutput[0] == '\0');
        /* 与 RunClean 相同的捕获语句序列（ParseOutput 之后补写全文） */
        strncpy(cr.RawOutput, sample, sizeof(cr.RawOutput) - 1);
        cr.RawOutput[sizeof(cr.RawOutput) - 1] = '\0';
        fprintf(f, "RawOutput_len=%d\n", (int)strlen(cr.RawOutput));
        fprintf(f, "RawOutput_keeps_gbk=%d\n",
                strstr(cr.RawOutput, "\xCE\xB4\xC4\xDC\xC7\xE5\xB3\xFD\xB4\xC5\xC5\xCC") != NULL);
        /* 分块写验证（与 OnCleanDone 的 AppendRawOutput 同一逻辑） */
        {
            int chunks = 0, maxLen = 0;
            raw_chunk_stats(cr.RawOutput, &chunks, &maxLen);
            fprintf(f, "Chunks=%d MaxChunkLen=%d\n", chunks, maxLen);
            fprintf(f, "Chunk_max_ok=%d\n", maxLen <= RAW_CHUNK_MAX);
        }
        fprintf(f, "--- RawOutput full text ---\n%s\n", cr.RawOutput);
        fclose(f);
        BootLog("M0 parsefake mode done");
        return 0;
    }

    /* -logtest：日志框 GBK→英文翻译验证模式（不建窗口）。
     * 构造含真实中文 diskpart 输出的字符串：
     *   1) gbk_translate 输出应全 ASCII 且关键短语翻译为英文
     *      （如 "成功地清除"→"successfully cleaned"）；
     *   2) AppendLog(原文) 后 U盘\FirPE\Log\cleanup.log 应保留 GBK
     *      原文字节（文件写原文，方便排查命令真实输出）。
     * 结果写 exe 同目录 log-test.txt */
    if (lpCmdLine && strstr(lpCmdLine, "-logtest")) {
        char path[MAX_PATH];
        char filt[512];
        /* 真实中文 diskpart + pnputil 输出的 GBK 字节（.NET GBK 936 实测）：
         * "DiskPart 成功地清除了磁盘。 正在添加驱动程序包: ps3stor.inf
         * 已成功添加驱动程序程序包。 发布名称: oem0.inf" */
        static const char raw[] =
            "DiskPart \xB3\xC9\xB9\xA6\xB5\xD8\xC7\xE5\xB3\xFD\xC1\xCB\xB4\xC5\xC5\xCC\xA1\xA3"
            " \xD5\xFD\xD4\xDA\xCC\xED\xBC\xD3\xC7\xFD\xB6\xAF\xB3\xCC\xD0\xF2\xB0\xFC: ps3stor.inf"
            " \xD2\xD1\xB3\xC9\xB9\xA6\xCC\xED\xBC\xD3\xC7\xFD\xB6\xAF\xB3\xCC\xD0\xF2\xB3\xCC\xD0\xF2\xB0\xFC\xA1\xA3"
            " \xB7\xA2\xB2\xBC\xC3\xFB\xB3\xC6: oem0.inf"
            " \xD0\xE9\xC4\xE2\xB4\xC5\xC5\xCC\xB7\xFE\xCE\xF1\xB4\xED\xCE\xF3:"
            " \xC7\xFD\xB6\xAF\xB3\xCC\xD0\xF2\xB0\xFC\xD7\xDC\xCA\xFD: 1"
            " \xD2\xD1\xCC\xED\xBC\xD3\xC7\xFD\xB6\xAF\xB3\xCC\xD0\xF2\xB0\xFC\xCA\xFD: 1";
        FILE* f;

        make_exe_dir_path(path, "log-test.txt");
        f = fopen(path, "w");
        if (!f) {
            BootLog("M0F -logtest cannot open log-test.txt");
            return 1;
        }
        gbk_translate(raw, filt, sizeof(filt));
        fprintf(f, "raw=%s\n", raw);
        fprintf(f, "translated=%s\n", filt);
        {
            int i, allAscii = 1;
            for (i = 0; filt[i]; i++)
                if ((unsigned char)filt[i] > 0x7F) { allAscii = 0; break; }
            fprintf(f, "translated_all_ascii=%d\n", allAscii);
        }
        /* 关键短语应被翻译 */
        fprintf(f, "has_successfully_cleaned=%d\n",
            strstr(filt, "successfully cleaned") != NULL ? 1 : 0);
        fprintf(f, "has_adding_driver_pkg=%d\n",
            strstr(filt, "adding driver package") != NULL ? 1 : 0);
        fprintf(f, "has_added_successfully=%d\n",
            strstr(filt, "driver package added successfully") != NULL ? 1 : 0);
        fprintf(f, "has_published_name=%d\n",
            strstr(filt, "published name") != NULL ? 1 : 0);
        fprintf(f, "has_vds_error=%d\n",
            strstr(filt, "virtual disk service error") != NULL ? 1 : 0);
        fprintf(f, "has_driver_pkgs_total=%d\n",
            strstr(filt, "driver packages total") != NULL ? 1 : 0);
        fprintf(f, "has_driver_pkgs_added=%d\n",
            strstr(filt, "driver packages added") != NULL ? 1 : 0);
        /* AppendLog 写文件：日志文件应保留 GBK 原文字节（文件名带本次
         * 启动时间戳 g_sessLogName；主路径 U盘\FirPE\Log\，其次
         * %TEMP%\FirpeCleaner\） */
        AppendLog(raw);
        {
            char tmp[MAX_PATH], logp[MAX_PATH];
            int keepsGbk = 0;
            char firpeLog[MAX_PATH];
            if (FindFirpeLogDir(firpeLog, sizeof(firpeLog))) {
                sprintf(logp, "%s\\%s", firpeLog, g_sessLogName);
                FILE* lf = fopen(logp, "rb");
                if (lf) {
                    char big[8192];
                    size_t n = fread(big, 1, sizeof(big) - 1, lf);
                    big[n] = '\0';
                    fclose(lf);
                    keepsGbk = (n > 0 && strstr(big, "\xD6\xD0\xCE\xC4\xC2\xD2\xC2\xEB") != NULL);
                }
            }
            if (!keepsGbk && GetTempPathA(MAX_PATH, tmp) && tmp[0]) {
                sprintf(logp, "%sFirpeCleaner\\%s", tmp, g_sessLogName);
                FILE* lf = fopen(logp, "rb");
                if (lf) {
                    char big[8192];
                    size_t n = fread(big, 1, sizeof(big) - 1, lf);
                    big[n] = '\0';
                    fclose(lf);
                    keepsGbk = (n > 0 && strstr(big, "\xD6\xD0\xCE\xC4\xC2\xD2\xC2\xEB") != NULL);
                }
            }
            fprintf(f, "cleanup_log_keeps_gbk=%d\n", keepsGbk);
        }
        fclose(f);
        BootLog("M0 logtest mode done");
        return 0;
    }

    /* -driverselftest：驱动模块验证模式（测 FindPs3StorInf + HasLinkdataDevice +
     * FindFirpeDriversDir + FindFirpeBcd，绝不执行 pnputil/sc/bcdedit 真实注入），
     * 结果写 exe 同目录 driver-test.txt */
    if (lpCmdLine && strstr(lpCmdLine, "-driverselftest")) {
        char path[MAX_PATH];
        char buf[MAX_PATH];
        const char* inf;
        FILE* f;

        make_exe_dir_path(path, "driver-test.txt");
        f = fopen(path, "w");
        if (!f) {
            BootLog("M0F -driverselftest cannot open driver-test.txt");
            return 1;
        }
        inf = FindPs3StorInf(NULL);
        fprintf(f, "FindPs3StorInf(NULL)=%s\n", inf ? inf : "NULL");
        fprintf(f, "HasLinkdataDevice=%d\n", HasLinkdataDevice());
        {
            int fd = FindFirpeDriversDir(buf, sizeof(buf));
            fprintf(f, "FindFirpeDriversDir=%d (%s)\n", fd, buf[0] ? buf : "none");
        }
        {
            int fb = FindFirpeBcd(buf, sizeof(buf));
            fprintf(f, "FindFirpeBcd=%d (%s)\n", fb, buf[0] ? buf : "none");
        }
        /* 盘符扫描 dry-run：打印每个存在盘符的 GetDriveTypeA 类型，
         * 验证 FindFirpeDriversDir 跳过 RAMDISK、优先 REMOVABLE 的判定依据 */
        fprintf(f, "--- drive type scan (dry-run) ---\n");
        {
            DWORD d = GetLogicalDrives();
            int i;
            for (i = 0; i < 26; i++) {
                char root[8];
                UINT dt;
                if (!(d & (1u << i))) continue;
                sprintf(root, "%c:\\", 'A' + i);
                dt = GetDriveTypeA(root);
                fprintf(f, "%c: type=%u", 'A' + i, (unsigned)dt);
                switch (dt) {
                case DRIVE_REMOVABLE: fprintf(f, " (REMOVABLE)"); break;
                case DRIVE_FIXED:     fprintf(f, " (FIXED)"); break;
                case DRIVE_RAMDISK:   fprintf(f, " (RAMDISK)"); break;
                case DRIVE_CDROM:     fprintf(f, " (CDROM)"); break;
                case DRIVE_REMOTE:    fprintf(f, " (REMOTE)"); break;
                case DRIVE_NO_ROOT_DIR: fprintf(f, " (NO_ROOT_DIR)"); break;
                default:              fprintf(f, " (UNKNOWN)"); break;
                }
                fprintf(f, "\n");
            }
        }
        fclose(f);
        BootLog("M0 driverselftest mode done");
        return 0;
    }

    /* -statustest：磁盘 online/offline 状态检测验证模式。先跑真实 diskpart
     * list disk（本机非管理员会因 diskpart 需提权而失败，如实记录），再用
     * 英文/中文（GBK）合成样例验证 ParseListDiskOutput 解析。
     * 结果写 exe 同目录 statustest.txt，不建窗口 */
    if (lpCmdLine && strstr(lpCmdLine, "-statustest")) {
        char path[MAX_PATH];
        int map[32];
        int i;
        FILE* f;

        make_exe_dir_path(path, "statustest.txt");
        f = fopen(path, "w");
        if (!f) {
            BootLog("M0F -statustest cannot open statustest.txt");
            return 1;
        }
        /* 1) 真实 diskpart（本机非提权预期失败；FirPE 内无 UAC 可正常运行） */
        if (GetDiskOnlineMap(map, 32) != 0) {
            fprintf(f, "GET_DISK_ONLINE_MAP_FAIL (diskpart not runnable here, "
                    "likely requires elevation; FirPE has no UAC)\n");
        } else {
            for (i = 0; i < 32; i++) {
                if (map[i] < 0) continue;
                fprintf(f, "disk%d=%s\n", i,
                        map[i] == 1 ? "online" : (map[i] == 0 ? "offline" : "unknown"));
            }
        }
        /* 2) 合成样例验证解析（英文 + 中文 GBK 字节转义：源码为 UTF-8，
         * 字面中文编译后是 UTF-8 字节，必须用 \x 转义构造 GBK 字节串） */
        fprintf(f, "--- synthetic parse ---\n");
        {
            static const char enSample[] =
                "Microsoft DiskPart version 10.0.19041.1\n"
                "\n"
                "  Disk ###  Status         Size     Free     Dyn  Gpt\n"
                "  --------  --------------  -------  -------  ---  ---\n"
                "  Disk 0    Online          476 GB   0 B      *   *\n"
                "  Disk 1    Offline         120 GB   0 B\n"
                "  Disk 2    Foreign         500 GB   0 B\n";
            /* 中文样例 GBK 字节：磁盘=B4C5 C5CC、状态=D7B4 CCAC、
             * 联机=C1AA BBFA、脱机=CDD1 BBFA、外部=CDE2 B2BF、
             * 大小=B4F3 D0A1、可用=BFC9 D3C3、动态=B6AF CCAC */
            static const char cnSample[] =
                "Microsoft DiskPart \xB0\xE6\xB1\xBE 10.0.19041.1\n"
                "\n"
                "  \xB4\xC5\xC5\xCC ###  \xD7\xB4\xCC\xAC         "
                "\xB4\xF3\xD0\xA1      \xBF\xC9\xD3\xC3     \xB6\xAF\xCC\xAC  Gpt\n"
                "  --------  ------------  --------  --------  ---  ---\n"
                "  \xB4\xC5\xC5\xCC 0    \xC1\xAA\xBB\xFA          476 GB    0 B      *   *\n"
                "  \xB4\xC5\xC5\xCC 1    \xCD\xD1\xBB\xFA          120 GB    0 B\n"
                "  \xB4\xC5\xC5\xCC 2    \xCD\xE2\xB2\xBF          500 GB    0 B\n";
            fprintf(f, "en parse rc=%d:\n", ParseListDiskOutput(enSample, map, 32));
            for (i = 0; i < 32; i++) {
                /* 全部打印（含 -1=unknown），确保样例 disk2=Foreign 的
                 * unknown 结果可从输出文件验证 */
                fprintf(f, "  en disk%d=%s\n", i,
                        map[i] == 1 ? "online" : (map[i] == 0 ? "offline" : "unknown"));
            }
            fprintf(f, "cn parse rc=%d:\n", ParseListDiskOutput(cnSample, map, 32));
            for (i = 0; i < 32; i++) {
                fprintf(f, "  cn disk%d=%s\n", i,
                        map[i] == 1 ? "online" : (map[i] == 0 ? "offline" : "unknown"));
            }
        }
        fclose(f);
        BootLog("M0 statustest mode done");
        return 0;
    }

    /* -lvtest：GUI 数据链路验证模式（见 DumpListViewToFile） */
    if (lpCmdLine && strstr(lpCmdLine, "-lvtest"))
        g_lvtest = 1;

    /* 注册公共控件：程序已嵌入 comctl32 v6 manifest（见 build.ps1 的
     * embedman 步骤），但 v6 下 SysListView32 类同样需要显式注册，
     * 仍调用 InitCommonControlsEx，否则 CreateWindowExA 创建 ListView
     * 会返回 NULL */
    INITCOMMONCONTROLSEX icc;
    memset(&icc, 0, sizeof(icc));
    icc.dwSize = sizeof(icc);
    icc.dwICC  = ICC_LISTVIEW_CLASSES;
    if (!InitCommonControlsEx(&icc)) {
        BootLog("M0F InitCommonControlsEx failed");
        return 1;
    }

    /* 注册窗口类 */
    WNDCLASSA wc;
    memset(&wc, 0, sizeof(wc));
    wc.lpfnWndProc   = WndProc;
    wc.hInstance     = hInstance;
    wc.hCursor       = LoadCursorA(NULL, IDC_ARROW);
    wc.hbrBackground = (HBRUSH)(COLOR_BTNFACE + 1);
    wc.lpszClassName = APP_CLASS;
    if (!RegisterClassA(&wc)) {
        BootLog("M0F RegisterClass failed");
        return 1;
    }

    /* 创建主窗口：客户区正好 900x580 */
    RECT rc = { 0, 0, APP_WIDTH, APP_HEIGHT };
    AdjustWindowRect(&rc, WS_OVERLAPPEDWINDOW, FALSE);
    g_mainWnd = CreateWindowExA(0, APP_CLASS, APP_TITLE,
        WS_OVERLAPPEDWINDOW,
        CW_USEDEFAULT, CW_USEDEFAULT,
        rc.right - rc.left, rc.bottom - rc.top,
        NULL, NULL, hInstance, NULL);
    if (!g_mainWnd) {
        BootLog("M0F CreateWindow failed");
        return 1;
    }
    BootLog("M1 window created");

    ShowWindow(g_mainWnd, nCmdShow);
    UpdateWindow(g_mainWnd);
    BootLog("M3 window shown, message loop started");

    /* -lvtest：dump 后立即退出（PostQuitMessage 后消息循环自然结束） */
    if (g_lvtest) {
        DumpListViewToFile();
        PostQuitMessage(0);
    }

    /* 消息循环 */
    MSG msg;
    while (GetMessageA(&msg, NULL, 0, 0) > 0) {
        TranslateMessage(&msg);
        DispatchMessageA(&msg);
    }
    return (int)msg.wParam;
}
