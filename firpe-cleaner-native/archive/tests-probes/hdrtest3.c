/* hdrtest3.c - 验证 ListView 列头文字是否真的写入（HDM_GETITEMA / HDM_GETITEMW 读回） */
#include <windows.h>
#include <stdio.h>
#include <string.h>
#include "src/patches.h"

#ifndef HDM_INSERTITEMA
#define HDM_INSERTITEMA (HDM_FIRST + 0x02)
#endif
#ifndef HDM_GETITEMW
#define HDM_GETITEMW    (HDM_FIRST + 0x0B)
#endif
#ifndef HDM_INSERTITEMW
#define HDM_INSERTITEMW (HDM_FIRST + 0x0A)
#endif

#ifndef RGB
#define RGB(r,g,b) ((COLORREF)(((BYTE)(r)|((WORD)(g)<<8))|(((DWORD)(BYTE)(b))<<16)))
#endif

int main(void)
{
    INITCOMMONCONTROLSEX icc;
    HWND top, lv, hdr;
    LVCOLUMNA lc;
    HDITEM hdi;
    char bufA[256];
    WCHAR bufW[256];
    int i;
    FILE* f = fopen("hdrtest3.txt", "w");
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

    {
        static const char* titles[6] = { "Disk","Model","Bus","Size GB","Free GB","Status" };
        for (i = 0; i < 6; i++) {
            memset(&lc, 0, sizeof(lc));
            lc.mask = LVCF_TEXT | LVCF_WIDTH | LVCF_SUBITEM;
            lc.cx = 80;
            lc.pszText = (char*)titles[i];
            lc.iSubItem = i;
            fprintf(f, "insert col %d ret=%ld\n", i,
                    (long)SendMessageA(lv, LVM_INSERTCOLUMNA, (WPARAM)i, (LPARAM)&lc));
        }
    }
    hdr = (HWND)SendMessageA(lv, LVM_GETHEADER, 0, 0);
    fprintf(f, "header=%p count=%d\n", (void*)hdr,
            (int)SendMessageA(hdr, HDM_GETITEMCOUNT, 0, 0));

    /* HDM_GETITEMA 读每列 */
    for (i = 0; i < 6; i++) {
        memset(&hdi, 0, sizeof(hdi));
        memset(bufA, 0, sizeof(bufA));
        hdi.mask = HDI_TEXT;
        hdi.pszText = bufA;
        hdi.cchTextMax = sizeof(bufA);
        SendMessageA(hdr, HDM_GETITEMA, (WPARAM)i, (LPARAM)&hdi);
        fprintf(f, "GETITEMA col %d = \"%s\"\n", i, bufA);
    }
    /* HDM_GETITEMW 读第 0 列（Unicode） */
    memset(&hdi, 0, sizeof(hdi));
    memset(bufW, 0, sizeof(bufW));
    hdi.mask = HDI_TEXT;
    hdi.pszText = (LPCSTR)bufW;
    hdi.cchTextMax = 128;
    SendMessageA(hdr, HDM_GETITEMW, 0, (LPARAM)&hdi);
    fprintf(f, "GETITEMW col 0 = \"%ls\"\n", bufW);

    fclose(f);
    return 0;
}
