/* msgtest6.c - ????? HDM_GETITEMA ?????? + HDM_SETTEXTCOLOR/HDM_SETBKCOLOR
 * ?? 9 ?? HDITEM?patches.h ????? SDK HDITEM?lvprobe.c ?? */
#include <windows.h>
#include <stdio.h>
#include <string.h>

typedef struct { UINT mask; int fmt; int cx; LPCSTR pszText; int cchTextMax; int iSubItem; int iImage; int iOrder; } LVCOLUMN_T;
typedef struct { DWORD dwSize; DWORD dwICC; } ICCEX;
extern BOOL WINAPI InitCommonControlsEx(const ICCEX* picc);

/* 9 ???patches.h ?? */
typedef struct { UINT mask; int cxy; LPCSTR pszText; HANDLE hbm; int cchTextMax; int fmt; LPARAM lParam; int iImage; int iOrder; } HDITEM9;
/* ?? SDK ??lvprobe.c ?? */
typedef struct { UINT mask; int cxy; LPCSTR pszText; HANDLE hbm; int cchTextMax; int fmt; LPARAM lParam; int iImage; int iOrder; UINT type; void* pvFilter; UINT state; } HDITEMFULL;

#define LVM_INSERTCOLUMNA 0x1061
#define LVM_GETHEADER     0x101F
#define HDM_GETITEMCOUNT  0x1200
#define HDM_GETITEMA      0x1203
#define HDM_GETTEXTCOLOR  0x1208
#define HDM_GETBKCOLOR    0x1207
#define HDM_SETTEXTCOLOR  0x1209
#define HDM_SETBKCOLOR    0x120A

int main(void)
{
    fprintf(stderr, "A: main enter\n");
    ICCEX icc; icc.dwSize = sizeof(icc); icc.dwICC = 1;
    fprintf(stderr, "B: before InitCommonControlsEx\n");
    InitCommonControlsEx(&icc);
    fprintf(stderr, "C: after InitCommonControlsEx\n");
    {
        HWND lv = CreateWindowExA(0, "SysListView32", "", WS_CHILD | WS_VISIBLE | 1,
                                  0, 0, 300, 200, GetDesktopWindow(), NULL, GetModuleHandleA(NULL), NULL);
        LVCOLUMN_T lc; char buf[128];
        HWND hdr; LRESULT r;
        int i;

        if (!lv) { fprintf(stderr, "FATAL: CreateWindowExA SysListView32 failed err=%lu\n", (unsigned long)GetLastError()); return 1; }

        memset(&lc, 0, sizeof(lc)); lc.mask = 0x1 | 0x2 | 0x8; lc.cx = 100; lc.pszText = "Disk"; lc.iSubItem = 0;
        SendMessageA(lv, LVM_INSERTCOLUMNA, 0, (LPARAM)&lc);
        memset(&lc, 0, sizeof(lc)); lc.mask = 0x1 | 0x2 | 0x8; lc.cx = 200; lc.pszText = "Model"; lc.iSubItem = 1;
        SendMessageA(lv, LVM_INSERTCOLUMNA, 1, (LPARAM)&lc);

        hdr = (HWND)SendMessageA(lv, LVM_GETHEADER, 0, 0);
        if (!hdr) { fprintf(stderr, "FATAL: LVM_GETHEADER returned NULL\n"); return 1; }
        fprintf(stderr, "hdr=%p cols=%d\n", (void*)hdr,
               hdr ? (int)SendMessageA(hdr, HDM_GETITEMCOUNT, 0, 0) : -1);

        /* 9 ??? */
        for (i = 0; i < 2; i++) {
            HDITEM9 hd;
            memset(buf, 0, sizeof(buf));
            memset(&hd, 0, sizeof(hd));
            hd.mask = 2; hd.pszText = buf; hd.cchTextMax = sizeof(buf);
            r = SendMessageA(hdr, HDM_GETITEMA, (WPARAM)i, (LPARAM)&hd);
            fprintf(stderr, "9-field  col %d ret=%ld text=\"%s\" (GetLastError=%lu)\n", i, (long)r, buf, (unsigned long)GetLastError());
        }
        /* ??? */
        for (i = 0; i < 2; i++) {
            HDITEMFULL hd;
            memset(buf, 0, sizeof(buf));
            memset(&hd, 0, sizeof(hd));
            hd.mask = 2; hd.pszText = buf; hd.cchTextMax = sizeof(buf);
            r = SendMessageA(hdr, HDM_GETITEMA, (WPARAM)i, (LPARAM)&hd);
            fprintf(stderr, "full     col %d ret=%ld text=\"%s\"\n", i, (long)r, buf);
        }

        /* HDM_SETTEXTCOLOR / HDM_SETBKCOLOR ???? */
        fprintf(stderr, "color before: text=0x%lX bk=0x%lX\n",
               (unsigned long)SendMessageA(hdr, HDM_GETTEXTCOLOR, 0, 0),
               (unsigned long)SendMessageA(hdr, HDM_GETBKCOLOR, 0, 0));
        SendMessageA(hdr, HDM_SETTEXTCOLOR, 0, (LPARAM)RGB(0, 0, 0));
        SendMessageA(hdr, HDM_SETBKCOLOR,   0, (LPARAM)RGB(255, 255, 255));
        fprintf(stderr, "color after : text=0x%lX bk=0x%lX\n",
               (unsigned long)SendMessageA(hdr, HDM_GETTEXTCOLOR, 0, 0),
               (unsigned long)SendMessageA(hdr, HDM_GETBKCOLOR, 0, 0));

        /* LVM_SETTEXTCOLOR/LVM_SETBKCOLOR ???? */
        fprintf(stderr, "lv color before: text=0x%lX bk=0x%lX\n",
               (unsigned long)SendMessageA(lv, 0x1003, 0, 0),
               (unsigned long)SendMessageA(lv, 0x1000, 0, 0));
        SendMessageA(lv, 0x1004, 0, (LPARAM)RGB(0, 0, 0));
        SendMessageA(lv, 0x1001, 0, (LPARAM)RGB(255, 255, 255));
        fprintf(stderr, "lv color after : text=0x%lX bk=0x%lX\n",
               (unsigned long)SendMessageA(lv, 0x1003, 0, 0),
               (unsigned long)SendMessageA(lv, 0x1000, 0, 0));

        DestroyWindow(lv);
    }
    fprintf(stderr, "== done ==\n");
    return 0;
}
