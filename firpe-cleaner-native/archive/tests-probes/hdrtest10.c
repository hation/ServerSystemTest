/* hdrtest10.c - 判断 SysHeader32 / SysListView32 窗口 Unicode 标志与列头渲染 */
#include <windows.h>
#include <stdio.h>
#include <string.h>
#include "src/patches.h"

#define LVM_INSERTCOLUMNA 0x1061
#define HDM_GETITEMA      0x1203
#define HDM_GETITEMW      0x120B
#define HDI_TEXT_MASK     0x0002

int main(void)
{
    INITCOMMONCONTROLSEX icc;
    HWND top, lv, hdr, hdr2;
    LVCOLUMNA lc;
    HDITEM hdi;
    char bufA[256];
    WCHAR bufW[256];
    int i;
    FILE* f = fopen("hdrtest10.txt", "w");
    if (!f) return 1;

    memset(&icc, 0, sizeof(icc));
    icc.dwSize = sizeof(icc);
    icc.dwICC  = ICC_LISTVIEW_CLASSES;
    if (!InitCommonControlsEx(&icc)) { fprintf(f, "ICC_FAIL\n"); fclose(f); return 1; }
    top = CreateWindowExA(0, "STATIC", "t", WS_OVERLAPPED, 0, 0, 500, 300,
                          NULL, NULL, GetModuleHandleA(NULL), NULL);
    lv = CreateWindowExA(0, "SysListView32", "lv",
                         WS_CHILD | WS_VISIBLE | LVS_REPORT, 0, 0, 500, 300,
                         top, NULL, GetModuleHandleA(NULL), NULL);
    hdr2 = CreateWindowExA(0, "SysHeader32", "h2",
                           WS_CHILD | WS_VISIBLE, 0, 60, 500, 60,
                           top, NULL, GetModuleHandleA(NULL), NULL);

    fprintf(f, "IsWindowUnicode(lv)=%d IsWindowUnicode(lv->hdr)=%d IsWindowUnicode(standalone hdr)=%d\n",
            IsWindowUnicode(lv), IsWindowUnicode(hdr2), IsWindowUnicode(hdr2));

    /* ListView 插列（真实 mask） */
    for (i = 0; i < 6; i++) {
        static const char* t[6] = { "Disk","Model","Bus","Size GB","Free GB","Status" };
        memset(&lc, 0, sizeof(lc));
        lc.mask = 0x0004 | 0x0002 | 0x0008;
        lc.cx = 80;
        lc.pszText = (char*)t[i];
        lc.iSubItem = i;
        SendMessageA(lv, LVM_INSERTCOLUMNA, (WPARAM)i, (LPARAM)&lc);
    }
    hdr = (HWND)SendMessageA(lv, LVM_GETHEADER, 0, 0);
    fprintf(f, "IsWindowUnicode(ListView internal header)=%d\n", IsWindowUnicode(hdr));

    /* 读回：GETITEMA（A）与 GETITEMW（W）对比 */
    for (i = 0; i < 6; i++) {
        memset(&hdi, 0, sizeof(hdi)); memset(bufA, 0, sizeof(bufA));
        hdi.mask = HDI_TEXT_MASK; hdi.pszText = bufA; hdi.cchTextMax = sizeof(bufA);
        SendMessageA(hdr, HDM_GETITEMA, i, (LPARAM)&hdi);
        fprintf(f, "GETITEMA col%d = \"%s\"\n", i, bufA);
    }
    for (i = 0; i < 6; i++) {
        memset(&hdi, 0, sizeof(hdi)); memset(bufW, 0, sizeof(bufW));
        hdi.mask = HDI_TEXT_MASK; hdi.pszText = (LPCSTR)bufW; hdi.cchTextMax = 128;
        SendMessageA(hdr, HDM_GETITEMW, i, (LPARAM)&hdi);
        fprintf(f, "GETITEMW col%d = \"%ls\"\n", i, bufW);
    }

    fclose(f);
    return 0;
}
