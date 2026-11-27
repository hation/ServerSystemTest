/* hdrtest11.c - 决定性：用 0x1062(W) vs 0x1061(A) 插列，SendMessageW 读回比较 */
#include <windows.h>
#include <stdio.h>
#include <string.h>
#include "src/patches.h"

#define HDM_GETITEMW 0x120B
#define HDI_TEXT_MASK 0x0002

typedef struct {
    UINT   mask;
    int    fmt;
    int    cx;
    LPCWSTR pszText;
    int    cchTextMax;
    int    iSubItem;
    int    iImage;
    int    iOrder;
} LVCOLUMNW_T;

typedef struct {
    UINT   mask;
    int    cxy;
    LPWSTR pszText;
    HANDLE hbm;
    int    cchTextMax;
    int    fmt;
    LPARAM lParam;
    int    iImage;
    int    iOrder;
} HDITEMW_T;

int main(void)
{
    INITCOMMONCONTROLSEX icc;
    HWND top, lv, hdr;
    LVCOLUMNA lcA;
    LVCOLUMNW_T lcW;
    HDITEMW_T hdiW;
    WCHAR wbuf[64];
    int i, j;
    FILE* f = fopen("hdrtest11.txt", "w");
    if (!f) return 1;

    memset(&icc, 0, sizeof(icc));
    icc.dwSize = sizeof(icc);
    icc.dwICC  = ICC_LISTVIEW_CLASSES;
    if (!InitCommonControlsEx(&icc)) { fprintf(f, "ICC_FAIL\n"); fclose(f); return 1; }
    top = CreateWindowExA(0, "STATIC", "t", WS_OVERLAPPED, 0, 0, 500, 300,
                          NULL, NULL, GetModuleHandleA(NULL), NULL);

    /* A: 0x1061 + LVCOLUMNA(mask=0x000E) */
    lv = CreateWindowExA(0, "SysListView32", "lv",
                         WS_CHILD | WS_VISIBLE | LVS_REPORT, 0, 0, 500, 300,
                         top, NULL, GetModuleHandleA(NULL), NULL);
    memset(&lcA, 0, sizeof(lcA));
    lcA.mask = 0x0004 | 0x0002 | 0x0008;
    lcA.cx = 80; lcA.pszText = (char*)"Disk"; lcA.iSubItem = 0;
    fprintf(f, "A: 0x1061 ANSI insert ret=%ld\n",
            (long)SendMessageA(lv, 0x1061, 0, (LPARAM)&lcA));
    hdr = (HWND)SendMessageA(lv, LVM_GETHEADER, 0, 0);
    memset(&hdiW, 0, sizeof(hdiW)); memset(wbuf, 0, sizeof(wbuf));
    hdiW.mask = HDI_TEXT_MASK; hdiW.pszText = wbuf; hdiW.cchTextMax = 64;
    SendMessageW(hdr, HDM_GETITEMW, 0, (LPARAM)&hdiW);
    fprintf(f, "A: GETITEMW(W) = \"%ls\" hex:", wbuf);
    for (j = 0; j < 8 && wbuf[j]; j++) fprintf(f, " %04X", wbuf[j]);
    fprintf(f, "\n");
    DestroyWindow(lv);

    /* B: 0x1062 + LVCOLUMNW_T(mask=0x000E, L"Disk") */
    lv = CreateWindowExA(0, "SysListView32", "lv",
                         WS_CHILD | WS_VISIBLE | LVS_REPORT, 0, 0, 500, 300,
                         top, NULL, GetModuleHandleA(NULL), NULL);
    memset(&lcW, 0, sizeof(lcW));
    lcW.mask = 0x0004 | 0x0002 | 0x0008;
    lcW.cx = 80; lcW.pszText = L"Disk"; lcW.iSubItem = 0;
    fprintf(f, "B: 0x1062 W insert ret=%ld\n",
            (long)SendMessageA(lv, 0x1062, 0, (LPARAM)&lcW));
    hdr = (HWND)SendMessageA(lv, LVM_GETHEADER, 0, 0);
    memset(&hdiW, 0, sizeof(hdiW)); memset(wbuf, 0, sizeof(wbuf));
    hdiW.mask = HDI_TEXT_MASK; hdiW.pszText = wbuf; hdiW.cchTextMax = 64;
    SendMessageW(hdr, HDM_GETITEMW, 0, (LPARAM)&hdiW);
    fprintf(f, "B: GETITEMW(W) = \"%ls\" hex:", wbuf);
    for (j = 0; j < 8 && wbuf[j]; j++) fprintf(f, " %04X", wbuf[j]);
    fprintf(f, "\n");

    /* C: 0x1063 + LVCOLUMNW_T（若 INSERTCOLUMNW=0x1063 则 B 失败 C 成功） */
    memset(&lcW, 0, sizeof(lcW));
    lcW.mask = 0x0004 | 0x0002 | 0x0008;
    lcW.cx = 80; lcW.pszText = L"Bus"; lcW.iSubItem = 0;
    fprintf(f, "C: 0x1063 W insert ret=%ld count=%d\n",
            (long)SendMessageA(lv, 0x1063, 0, (LPARAM)&lcW),
            (int)SendMessageA(hdr, HDM_GETITEMCOUNT, 0, 0));
    DestroyWindow(lv);

    fclose(f);
    return 0;
}
