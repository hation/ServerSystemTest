/* lvprobe.c - 本机 ListView 数据链路验证
 * 用法: lvprobe.exe <target exe 路径>
 * 启动目标程序 → 等待主窗口 → EnumChildWindows 找 SysListView32 →
 * 打印行列数、每行每列文本（LVM_GETITEMTEXTA）、checkbox 状态、
 * comctl32 版本（目标进程内 + 本进程）、ListView 字体 → 结束目标进程。
 * 消息号用 SDK 权威值（与 patches.h 是否一致单独对照）。
 */
#include <windows.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

/* TCC 缺 tlhelp32.h：手动声明 Toolhelp API（kernel32 导出） */
#define TH32CS_SNAPMODULE 0x00000008
#define MAX_MODULE_NAME32 255
typedef struct tagMODULEENTRY32 {
    DWORD   dwSize;
    DWORD   th32ModuleID;
    DWORD   th32ProcessID;
    DWORD   GlblcntUsage;
    DWORD   ProccntUsage;
    BYTE*   modBaseAddr;
    DWORD   modBaseSize;
    HMODULE hModule;
    char    szModule[MAX_MODULE_NAME32 + 1];
    char    szExePath[MAX_PATH];
} MODULEENTRY32;
typedef HANDLE(WINAPI* FNCreateToolhelp32Snapshot)(DWORD, DWORD);
typedef BOOL(WINAPI* FNModule32First)(HANDLE, MODULEENTRY32*);
typedef BOOL(WINAPI* FNModule32Next)(HANDLE, MODULEENTRY32*);

#define LVM_FIRST 0x1000
#define LVM_GETITEMCOUNT     (LVM_FIRST + 4)
#define LVM_GETHEADER        (LVM_FIRST + 31)   /* 0x101F，SDK 权威值 */
#define LVM_GETITEMTEXTA     (LVM_FIRST + 45)
#define LVM_GETITEMSTATE     (LVM_FIRST + 44)
#define LVIF_TEXT 0x0001
#define LVIS_STATEIMAGEMASK 0xF000

/* 与 patches.h 相同的 LVITEMA（已验证布局 == SDK） */
typedef struct {
    UINT   mask;
    int    iItem;
    int    iSubItem;
    UINT   state;
    UINT   stateMask;
    LPCSTR pszText;
    int    cchTextMax;
    int    iImage;
    LPARAM lParam;
    int    iIndent;
    int    iGroupId;
    UINT   cColumns;
    UINT*  puColumns;
    int*   piColFmt;
    int    iGroup;
} LVITEM_T;

/* HDITEMA（SDK 布局） */
typedef struct {
    UINT   mask;
    int    cch;
    LPCSTR pszText;
    HBITMAP hbm;
    int    cchTextMax;
    int    fmt;
    LPARAM lParam;
    int    iImage;
    int    iOrder;
    UINT   type;
    void*  pvFilter;
    UINT   state;
} HDITEM_T;
#define HDI_TEXT 0x0002
#define HDM_GETITEMCOUNT (0x1200 + 0)
#define HDM_GETITEMA     (0x1200 + 3)

static HWND g_listView;
static HWND g_header;

static BOOL CALLBACK EnumChildProc(HWND hwnd, LPARAM lParam)
{
    char cls[64];
    (void)lParam;
    if (GetClassNameA(hwnd, cls, sizeof(cls)) > 0) {
        if (strcmp(cls, "SysListView32") == 0 && !g_listView) {
            g_listView = hwnd;
        } else if (strcmp(cls, "SysHeader32") == 0 && !g_header) {
            g_header = hwnd;
        }
    }
    return TRUE;   /* 继续枚举，两类控件都要 */
}

typedef DWORD(WINAPI* FNGVFS)(LPCSTR, LPDWORD);
typedef BOOL(WINAPI* FNGVFIA)(LPCSTR, DWORD, DWORD, void**);
typedef BOOL(WINAPI* FNVQVA)(LPCSTR, LPCSTR, void**, UINT*);

/* 打印 dll 文件版本；version.dll 动态加载（TCC 未必默认链接） */
static void print_dll_version(const char* path, const char* tag)
{
    HMODULE v = LoadLibraryA("version.dll");
    DWORD handle = 0;
    DWORD sz;
    void* data = NULL;
    if (!v) { printf("[comctl32 %s] (version.dll not loadable, path=%s)\n", tag, path); return; }
    {
        FNGVFS pSize = (FNGVFS)GetProcAddress(v, "GetFileVersionInfoSizeA");
        FNGVFIA pInfo = (FNGVFIA)GetProcAddress(v, "GetFileVersionInfoA");
        FNVQVA pQuery = (FNVQVA)GetProcAddress(v, "VerQueryValueA");
        if (!pSize || !pInfo || !pQuery) { FreeLibrary(v); return; }
        sz = pSize(path, &handle);
        if (sz > 0) {
            data = malloc(sz);
            if (data && pInfo(path, 0, sz, &data)) {
                VS_FIXEDFILEINFO* ffi = NULL;
                UINT flen = 0;
                if (pQuery(data, "\\", (void**)&ffi, &flen) && ffi) {
                    printf("[comctl32 %s] path=%s version=%d.%d.%d.%d\n",
                           tag, path,
                           HIWORD(ffi->dwFileVersionMS), LOWORD(ffi->dwFileVersionMS),
                           HIWORD(ffi->dwFileVersionLS), LOWORD(ffi->dwFileVersionLS));
                }
            }
            if (data) free(data);
        }
    }
    FreeLibrary(v);
}

static void print_comctl32_version(DWORD pid, const char* tag)
{
    /* 目标进程模块列表里找 comctl32.dll（动态取 Toolhelp API，TCC 无头文件） */
    HMODULE k32 = GetModuleHandleA("kernel32.dll");
    FNCreateToolhelp32Snapshot pSnap = (FNCreateToolhelp32Snapshot)GetProcAddress(k32, "CreateToolhelp32Snapshot");
    FNModule32First pFirst = (FNModule32First)GetProcAddress(k32, "Module32FirstA");
    FNModule32Next pNext = (FNModule32Next)GetProcAddress(k32, "Module32NextA");
    if (!pSnap || !pFirst || !pNext) return;
    HANDLE snap = pSnap(TH32CS_SNAPMODULE, pid);
    if (snap != INVALID_HANDLE_VALUE) {
        MODULEENTRY32 me;
        me.dwSize = sizeof(me);
        if (pFirst(snap, &me)) {
            do {
                if (_stricmp(me.szModule, "comctl32.dll") == 0) {
                    print_dll_version(me.szExePath, tag);
                }
            } while (pNext(snap, &me));
        }
        CloseHandle(snap);
    }
}

int main(int argc, char** argv)
{
    STARTUPINFOA si;
    PROCESS_INFORMATION pi;
    HWND mainWnd = NULL;
    HWND hdr;
    int nRows, nCols, i, j;
    int attempts;

    if (argc < 2) { printf("usage: lvprobe <target-exe>\n"); return 2; }

    memset(&si, 0, sizeof(si));
    si.cb = sizeof(si);
    memset(&pi, 0, sizeof(pi));
    if (!CreateProcessA(NULL, argv[1], NULL, NULL, FALSE, 0, NULL, NULL, &si, &pi)) {
        printf("[fail] CreateProcess %s err=%lu\n", argv[1], (unsigned long)GetLastError());
        return 1;
    }
    printf("[ok] launched pid=%lu\n", (unsigned long)pi.dwProcessId);

    /* 等待主窗口（最多 15 秒） */
    for (attempts = 0; attempts < 150; attempts++) {
        mainWnd = FindWindowA("FirpeCleanerWndClass", NULL);
        if (mainWnd) break;
        Sleep(100);
    }
    if (!mainWnd) {
        printf("[fail] main window not found in 15s\n");
        TerminateProcess(pi.hProcess, 1);
        CloseHandle(pi.hProcess); CloseHandle(pi.hThread);
        return 1;
    }
    printf("[ok] main window found\n");
    print_comctl32_version(pi.dwProcessId, "target");

    /* 等 PopulateDiskList 完成（WM_CREATE 同步完成，Sleep 保险） */
    Sleep(500);

    g_listView = NULL;
    g_header = NULL;
    EnumChildWindows(mainWnd, EnumChildProc, 0);
    if (!g_listView) {
        printf("[fail] SysListView32 not found\n");
    } else {
        char wtext[64];
        LRESULT hdrRaw = SendMessageA(g_listView, LVM_GETHEADER, 0, 0);
        nRows = (int)SendMessageA(g_listView, LVM_GETITEMCOUNT, 0, 0);
        hdr = g_header ? g_header : (HWND)hdrRaw;
        nCols = hdr ? (int)SendMessageA(hdr, HDM_GETITEMCOUNT, 0, 0) : 0;
        GetWindowTextA(g_listView, wtext, sizeof(wtext));
        printf("[listview] rows=%d cols=%d (header via enum=%p, LVM_GETHEADER raw=0x%lX, IsWindow=%d) class-text=%s\n",
               nRows, nCols, (void*)g_header, (unsigned long)hdrRaw,
               g_header ? IsWindow(g_header) : 0, wtext);

        /* 列头文本 */
        for (j = 0; j < nCols && hdr; j++) {
            HDITEM_T hd;
            char hbuf[128];
            memset(&hd, 0, sizeof(hd));
            hd.mask = HDI_TEXT;
            hd.pszText = hbuf;
            hd.cchTextMax = sizeof(hbuf);
            if (SendMessageA(hdr, HDM_GETITEMA, (WPARAM)j, (LPARAM)&hd)) {
                hbuf[hd.cchTextMax - 1] = '\0';
                printf("  col %d header: \"%s\"\n", j, hbuf);
            } else {
                printf("  col %d header: (read failed)\n", j);
            }
        }

        /* 每行每列文本 */
        for (i = 0; i < nRows; i++) {
            LRESULT st = SendMessageA(g_listView, LVM_GETITEMSTATE, (WPARAM)i,
                                      (LPARAM)LVIS_STATEIMAGEMASK);
            printf("  row %d stateimg=%ld (checked=%d)\n", i, (long)st,
                   (int)((st >> 12) == 2));
            for (j = 0; j < nCols; j++) {
                LVITEM_T it;
                char buf[512];
                memset(&it, 0, sizeof(it));
                it.mask = LVIF_TEXT;
                it.iItem = i;
                it.iSubItem = j;
                it.pszText = buf;
                it.cchTextMax = sizeof(buf);
                LRESULT r = SendMessageA(g_listView, LVM_GETITEMTEXTA, (WPARAM)i, (LPARAM)&it);
                buf[sizeof(buf) - 1] = '\0';
                printf("    col %d (ret=%ld): \"%s\"\n", j, (long)r, buf);
            }
        }
        if (nRows == 0) printf("  (no rows)\n");

        /* ListView 字体 */
        {
            HFONT hf = (HFONT)SendMessageA(g_listView, WM_GETFONT, 0, 0);
            if (hf) {
                LOGFONTA lf;
                memset(&lf, 0, sizeof(lf));
                if (GetObjectA(hf, sizeof(lf), &lf)) {
                    printf("[font] face=%s height=%d weight=%d charset=%d\n",
                           lf.lfFaceName, lf.lfHeight, lf.lfWeight, (int)lf.lfCharSet);
                }
            } else {
                printf("[font] WM_GETFONT -> NULL\n");
            }
        }

        /* 扩展风格 */
        {
            LRESULT ex = SendMessageA(g_listView, LVM_FIRST + 55, 0, 0); /* GETEXTENDEDLISTVIEWSTYLE */
            printf("[extstyle] %lx (grid=1 checkbox=4 fullrow=0x20)\n", (unsigned long)ex);
        }
    }

    /* 本进程 comctl32（无 manifest 的 TCC 程序默认加载的版本） */
    {
        HMODULE h = GetModuleHandleA("comctl32.dll");
        printf("[comctl32 probe] loaded=%d\n", h ? 1 : 0);
        if (h) {
            char path[MAX_PATH];
            if (GetModuleFileNameA(h, path, MAX_PATH) > 0) {
                print_dll_version(path, "probe");
            }
        }
    }

    TerminateProcess(pi.hProcess, 0);
    CloseHandle(pi.hProcess);
    CloseHandle(pi.hThread);
    printf("[done]\n");
    return 0;
}
