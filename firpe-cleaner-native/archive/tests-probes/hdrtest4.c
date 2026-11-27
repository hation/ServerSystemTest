/* hdrtest4.c - 判定 0x1061 是否为 ANSI 建列消息：分别用 0x1061(ANSI) / 0x1062(W) 插列，
 * 用 HDM_GETITEMA / HDM_GETITEMW 读回列头文字。 */
#include <windows.h>
#include <stdio.h>
#include <string.h>
#include "src/patches.h"

#ifndef RGB
#define RGB(r,g,b) ((COLORREF)(((BYTE)(r)|((WORD)(g)<<8))|(((DWORD)(BYTE)(b))<<16)))
#endif

/* 完整 LVCOLUMNW：pszText 为 WCHAR*（字段偏移与 A 版一致） */
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

#define LVM_INSERTCOLUMNW 0x1062
#define HDM_GETITEMW      0x120B
#define HDI_TEXT_4        0x0004   /* 真实 HDI_TEXT */

static HWND make_lv(HWND top)
{
    return CreateWindowExA(0, "SysListView32", "lv",
                           WS_CHILD | WS_VISIBLE | LVS_REPORT, 0, 0, 500, 300,
                           top, NULL, GetModuleHandleA(NULL), NULL);
}

int main(void)
{
    INITCOMMONCONTROLSEX icc;
    HWND top, lv, hdr;
    LVCOLUMNA lcA;
    LVCOLUMNW_T lcW;
    HDITEM hdi;
    char bufA[256];
    WCHAR bufW[256];
    FILE* f = fopen("hdrtest4.txt", "w");
    if (!f) return 1;

    memset(&icc, 0, sizeof(icc));
    icc.dwSize = sizeof(icc);
    icc.dwICC  = ICC_LISTVIEW_CLASSES;
    if (!InitCommonControlsEx(&icc)) { fprintf(f, "ICC_FAIL\n"); fclose(f); return 1; }
    top = CreateWindowExA(0, "STATIC", "t", WS_OVERLAPPED, 0, 0, 500, 300,
                          NULL, NULL, GetModuleHandleA(NULL), NULL);

    /* 场景1：0x1061 插 ANSI 文本 */
    lv = make_lv(top);
    memset(&lcA, 0, sizeof(lcA));
    lcA.mask = LVCF_TEXT | LVCF_WIDTH | LVCF_SUBITEM;
    lcA.cx = 80;
    lcA.pszText = (char*)"Disk";
    lcA.iSubItem = 0;
    fprintf(f, "case1: 0x1061 ANSI insert ret=%ld\n",
            (long)SendMessageA(lv, LVM_INSERTCOLUMNA, 0, (LPARAM)&lcA));
    hdr = (HWND)SendMessageA(lv, LVM_GETHEADER, 0, 0);
    memset(&hdi, 0, sizeof(hdi)); memset(bufA, 0, sizeof(bufA));
    hdi.mask = HDI_TEXT_4; hdi.pszText = bufA; hdi.cchTextMax = sizeof(bufA);
    SendMessageA(hdr, HDM_GETITEMA, 0, (LPARAM)&hdi);
    fprintf(f, "case1: GETITEMA = \"%s\"\n", bufA);
    memset(&hdi, 0, sizeof(hdi)); memset(bufW, 0, sizeof(bufW));
    hdi.mask = HDI_TEXT_4; hdi.pszText = (LPCSTR)bufW; hdi.cchTextMax = 128;
    SendMessageA(hdr, HDM_GETITEMW, 0, (LPARAM)&hdi);
    fprintf(f, "case1: GETITEMW = \"%ls\"\n", bufW);
    DestroyWindow(lv);

    /* 场景2：0x1062 插 Unicode 文本 */
    lv = make_lv(top);
    memset(&lcW, 0, sizeof(lcW));
    lcW.mask = LVCF_TEXT | LVCF_WIDTH | LVCF_SUBITEM;
    lcW.cx = 80;
    lcW.pszText = L"Disk";
    lcW.iSubItem = 0;
    fprintf(f, "case2: 0x1062 W insert ret=%ld\n",
            (long)SendMessageA(lv, LVM_INSERTCOLUMNW, 0, (LPARAM)&lcW));
    hdr = (HWND)SendMessageA(lv, LVM_GETHEADER, 0, 0);
    memset(&hdi, 0, sizeof(hdi)); memset(bufA, 0, sizeof(bufA));
    hdi.mask = HDI_TEXT_4; hdi.pszText = bufA; hdi.cchTextMax = sizeof(bufA);
    SendMessageA(hdr, HDM_GETITEMA, 0, (LPARAM)&hdi);
    fprintf(f, "case2: GETITEMA = \"%s\"\n", bufA);
    memset(&hdi, 0, sizeof(hdi)); memset(bufW, 0, sizeof(bufW));
    hdi.mask = HDI_TEXT_4; hdi.pszText = (LPCSTR)bufW; hdi.cchTextMax = 128;
    SendMessageA(hdr, HDM_GETITEMW, 0, (LPARAM)&hdi);
    fprintf(f, "case2: GETITEMW = \"%ls\"\n", bufW);
    DestroyWindow(lv);

    /* 场景3：0x1061 插 Unicode 文本（若 0x1061 其实是 INSERTCOLUMNW，则能存上） */
    lv = make_lv(top);
    memset(&lcW, 0, sizeof(lcW));
    lcW.mask = LVCF_TEXT | LVCF_WIDTH | LVCF_SUBITEM;
    lcW.cx = 80;
    lcW.pszText = L"Disk";
    lcW.iSubItem = 0;
    fprintf(f, "case3: 0x1061 with W-text insert ret=%ld\n",
            (long)SendMessageA(lv, LVM_INSERTCOLUMNA, 0, (LPARAM)&lcW));
    hdr = (HWND)SendMessageA(lv, LVM_GETHEADER, 0, 0);
    memset(&hdi, 0, sizeof(hdi)); memset(bufW, 0, sizeof(bufW));
    hdi.mask = HDI_TEXT_4; hdi.pszText = (LPCSTR)bufW; hdi.cchTextMax = 128;
    SendMessageA(hdr, HDM_GETITEMW, 0, (LPARAM)&hdi);
    fprintf(f, "case3: GETITEMW = \"%ls\"\n", bufW);
    DestroyWindow(lv);

    fclose(f);
    return 0;
}
