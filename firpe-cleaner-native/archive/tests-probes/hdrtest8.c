/* hdrtest8.c - 验证 LVCF_TEXT 真实值：
 * ListView 插 4 列，mask 各异（均含 LVCF_WIDTH=0x0002），读回 header 看哪列存了文本 */
#include <windows.h>
#include <stdio.h>
#include <string.h>
#include "src/patches.h"

#define LVM_INSERTCOLUMNA 0x1061
#define HDM_GETITEMA      0x1203
#define HDM_GETITEMW      0x120B
#define HDI_TEXT_MASK     0x0002   /* 实测文本 mask */

int main(void)
{
    INITCOMMONCONTROLSEX icc;
    HWND top, lv, hdr;
    LVCOLUMNA lc;
    HDITEM hdi;
    char bufA[256];
    WCHAR bufW[256];
    int i;
    FILE* f = fopen("hdrtest8.txt", "w");
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
    if (!lv) { fprintf(f, "LV_FAIL\n"); fclose(f); return 1; }

    /* 4 列：mask 分别 0x0002|0x0001, 0x0002|0x0004, 0x0002|0x0008, 0x0002|0x0010 */
    {
        static const char* t[4] = { "T1","T2","T3","T4" };
        static const UINT m[4] = { 0x0003, 0x0006, 0x000A, 0x0012 };
        for (i = 0; i < 4; i++) {
            memset(&lc, 0, sizeof(lc));
            lc.mask = m[i];
            lc.cx = 80;
            lc.pszText = (char*)t[i];
            lc.iSubItem = i;
            fprintf(f, "insert col%d mask=0x%04X ret=%ld\n", i, m[i],
                    (long)SendMessageA(lv, LVM_INSERTCOLUMNA, (WPARAM)i, (LPARAM)&lc));
        }
    }
    hdr = (HWND)SendMessageA(lv, LVM_GETHEADER, 0, 0);
    fprintf(f, "header count=%d\n", (int)SendMessageA(hdr, HDM_GETITEMCOUNT, 0, 0));

    for (i = 0; i < 4; i++) {
        memset(&hdi, 0, sizeof(hdi)); memset(bufA, 0, sizeof(bufA));
        hdi.mask = HDI_TEXT_MASK; hdi.pszText = bufA; hdi.cchTextMax = sizeof(bufA);
        SendMessageA(hdr, HDM_GETITEMA, i, (LPARAM)&hdi);
        fprintf(f, "GETITEMA(mask=0x0002) col%d = \"%s\"\n", i, bufA);
    }
    for (i = 0; i < 4; i++) {
        memset(&hdi, 0, sizeof(hdi)); memset(bufW, 0, sizeof(bufW));
        hdi.mask = HDI_TEXT_MASK; hdi.pszText = (LPCSTR)bufW; hdi.cchTextMax = 128;
        SendMessageA(hdr, HDM_GETITEMW, i, (LPARAM)&hdi);
        fprintf(f, "GETITEMW(mask=0x0002) col%d = \"%ls\"\n", i, bufW);
    }

    fclose(f);
    return 0;
}
