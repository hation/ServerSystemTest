/* hdrtest.c - 一次性实测程序：确定 ListView / SysHeader32 颜色相关消息的真实值
 * 方法：创建真实控件，对候选消息值发 SendMessage，再用只读消息读回验证。
 * 结果写 hdrtest.txt（exe 同目录）。仅供本次修复验证，用后删除。 */
#include <windows.h>
#include <stdio.h>
#include <string.h>
#include <stdarg.h>
#include "src/patches.h"

static FILE* g_f;

static void out(const char* fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    vfprintf(g_f, fmt, ap);
    vfprintf(stdout, fmt, ap);
    va_end(ap);
    fflush(g_f);
    fflush(stdout);
}

/* RGB 宏保险（TCC windef.h 通常已定义） */
#ifndef RGB
#define RGB(r,g,b) ((COLORREF)(((BYTE)(r)|((WORD)(g)<<8))|(((DWORD)(BYTE)(b))<<16)))
#endif

int main(void)
{
    INITCOMMONCONTROLSEX icc;
    HWND top, lv, hdr;
    LVCOLUMNA lc;
    LVITEMA li;
    HDITEM hdi;
    char buf[128];
    LRESULT r;
    COLORREF tc, bc;
    char path[MAX_PATH];
    DWORD len;

    memset(&icc, 0, sizeof(icc));
    icc.dwSize = sizeof(icc);
    icc.dwICC  = ICC_LISTVIEW_CLASSES;
    if (!InitCommonControlsEx(&icc)) { printf("InitCommonControlsEx failed\n"); return 1; }

    len = GetModuleFileNameA(NULL, path, MAX_PATH);
    if (len && len < MAX_PATH) {
        char* s = strrchr(path, '\\');
        if (s) *s = '\0';
    }
    strcat(path, "\\hdrtest.txt");
    g_f = fopen(path, "w");
    if (!g_f) { printf("cannot open %s\n", path); return 1; }

    top = CreateWindowExA(0, "STATIC", "t", WS_OVERLAPPED, 0, 0, 400, 300,
                          NULL, NULL, GetModuleHandleA(NULL), NULL);
    lv = CreateWindowExA(0, "SysListView32", "lv",
                         WS_CHILD | WS_VISIBLE | LVS_REPORT, 0, 0, 400, 300,
                         top, NULL, GetModuleHandleA(NULL), NULL);
    if (!lv) { out("FAIL: cannot create SysListView32\n"); return 1; }

    /* 插 6 列（真实值 0x1061） */
    {
        static const char* titles[6] = { "Disk","Model","Bus","Size GB","Free GB","Status" };
        int i;
        for (i = 0; i < 6; i++) {
            memset(&lc, 0, sizeof(lc));
            lc.mask = LVCF_TEXT | LVCF_WIDTH;
            lc.cx = 80;
            lc.pszText = (char*)titles[i];
            SendMessageA(lv, LVM_INSERTCOLUMNA, (WPARAM)i, (LPARAM)&lc);
        }
    }
    /* 插 1 行 */
    memset(&li, 0, sizeof(li));
    li.mask = LVIF_TEXT;
    li.pszText = (char*)"PhysicalDrive0";
    SendMessageA(lv, LVM_INSERTITEMA, 0, (LPARAM)&li);

    out("== ListView ==\n");
    r = SendMessageA(lv, LVM_GETITEMCOUNT, 0, 0);
    out("LVM_GETITEMCOUNT(0x1004) = %d (expect 1)\n", (int)r);

    tc = (COLORREF)SendMessageA(lv, LVM_GETTEXTCOLOR, 0, 0);
    out("default LVM_GETTEXTCOLOR(0x1023) = 0x%08lX\n", (unsigned long)tc);

    /* 候选 SETTEXTCOLOR = 0x1024 */
    SendMessageA(lv, 0x1024, 0, (LPARAM)RGB(255, 0, 0));
    tc = (COLORREF)SendMessageA(lv, LVM_GETTEXTCOLOR, 0, 0);
    out("after send 0x1024 RGB(255,0,0): GETTEXTCOLOR = 0x%08lX (0xFF0000 => 0x1024 IS SETTEXTCOLOR)\n",
        (unsigned long)tc);

    /* 候选 SETTEXTCOLOR = 0x1004（任务描述给的值） */
    SendMessageA(lv, 0x1004, 0, (LPARAM)RGB(0, 255, 0));
    tc = (COLORREF)SendMessageA(lv, LVM_GETTEXTCOLOR, 0, 0);
    r = SendMessageA(lv, LVM_GETITEMCOUNT, 0, 0);
    out("after send 0x1004 RGB(0,255,0): GETTEXTCOLOR = 0x%08lX, GETITEMCOUNT = %d (color unchanged => 0x1004 is GETITEMCOUNT, NOT SETTEXTCOLOR)\n",
        (unsigned long)tc, (int)r);

    /* LVM_SETBKCOLOR = 0x1001 */
    SendMessageA(lv, 0x1001, 0, (LPARAM)RGB(0, 0, 255));
    bc = (COLORREF)SendMessageA(lv, 0x1000, 0, 0);   /* LVM_GETBKCOLOR = 0x1000 */
    out("after send 0x1001 RGB(0,0,255): GETBKCOLOR(0x1000) = 0x%08lX (0x0000FF => 0x1001 IS SETBKCOLOR)\n",
        (unsigned long)bc);

    hdr = (HWND)SendMessageA(lv, LVM_GETHEADER, 0, 0);
    out("LVM_GETHEADER(0x101F) = %p (%s)\n", (void*)hdr, hdr ? "non-NULL" : "NULL");
    if (!hdr) return 1;

    out("\n== SysHeader32 ==\n");
    r = SendMessageA(hdr, HDM_GETITEMCOUNT, 0, 0);
    out("HDM_GETITEMCOUNT(0x1200) = %d (expect 6)\n", (int)r);
    memset(&hdi, 0, sizeof(hdi));
    hdi.mask = HDI_TEXT;
    hdi.pszText = buf;
    hdi.cchTextMax = sizeof(buf);
    r = SendMessageA(hdr, HDM_GETITEMA, 0, (LPARAM)&hdi);
    out("HDM_GETITEMA(0x1203) col0 = \"%s\" (ret=%d)\n", buf, (int)r);

    tc = (COLORREF)SendMessageA(hdr, HDM_GETTEXTCOLOR, 0, 0);
    out("default HDM_GETTEXTCOLOR(0x1209) = 0x%08lX\n", (unsigned long)tc);

    /* 0x120A 指针语义探测：若为 HDM_INSERTITEMW（指针消息），插一列列数+1 */
    memset(&hdi, 0, sizeof(hdi));
    hdi.mask = HDI_TEXT;
    hdi.pszText = (char*)"Probe";
    SendMessageA(hdr, 0x120A, (WPARAM)(-1), (LPARAM)&hdi);
    r = SendMessageA(hdr, HDM_GETITEMCOUNT, 0, 0);
    out("after send 0x120A(INSERTITEMW-like, ptr) : GETITEMCOUNT = %d (7 => 0x120A is INSERTITEMW; 6 => not)\n", (int)r);

    /* 0x1208 颜色写探测 */
    SendMessageA(hdr, 0x1208, 0, (LPARAM)RGB(255, 0, 0));
    tc = (COLORREF)SendMessageA(hdr, HDM_GETTEXTCOLOR, 0, 0);
    out("after send 0x1208 RGB(255,0,0): GETTEXTCOLOR = 0x%08lX (0xFF0000 => 0x1208 IS SETTEXTCOLOR)\n",
        (unsigned long)tc);

    /* 0x120A 颜色写探测：仅当上面证明 0x120A 不是指针消息时才发，否则跳过防崩溃 */
    if (r == 6) {
        SendMessageA(hdr, 0x120A, 0, (LPARAM)RGB(0, 255, 0));
        tc = (COLORREF)SendMessageA(hdr, HDM_GETTEXTCOLOR, 0, 0);
        out("after send 0x120A RGB(0,255,0): GETTEXTCOLOR = 0x%08lX (0x00FF00 => 0x120A IS SETTEXTCOLOR)\n",
            (unsigned long)tc);
    } else {
        out("0x120A is a pointer message (INSERTITEMW) - color-write on it would crash, SKIPPED\n");
    }

    /* 0x120B 指针语义探测：若为 HDM_GETITEMW（指针写），会填 hdi */
    memset(&hdi, 0, sizeof(hdi));
    memset(buf, 0, sizeof(buf));
    hdi.mask = HDI_TEXT;
    hdi.pszText = buf;
    hdi.cchTextMax = sizeof(buf);
    r = SendMessageA(hdr, 0x120B, 0, (LPARAM)&hdi);
    out("send 0x120B(GETITEMW-like, ptr): ret=%d buf=\"%s\" (buf filled => 0x120B is GETITEMW/pointer msg)\n",
        (int)r, buf);

    if (buf[0] == '\0') {
        /* 0x120B 不是指针消息 → 测颜色写 + 0x120C 读回 */
        SendMessageA(hdr, 0x120B, 0, (LPARAM)RGB(0, 0, 255));
        bc = (COLORREF)SendMessageA(hdr, 0x120C, 0, 0);
        out("after send 0x120B RGB(0,0,255): GETBKCOLOR(0x120C) = 0x%08lX (0x0000FF => 0x120B IS SETBKCOLOR, 0x120C IS GETBKCOLOR)\n",
            (unsigned long)bc);
    } else {
        out("0x120B is a pointer message - color-write on it would crash, SKIPPED\n");
    }

    out("\nDONE\n");
    fclose(g_f);
    DestroyWindow(lv);
    DestroyWindow(top);
    return 0;
}
