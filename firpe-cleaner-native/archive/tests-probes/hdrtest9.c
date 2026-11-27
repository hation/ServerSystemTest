/* hdrtest9.c - ListView 列头存储内容检查：
 * LVM_INSERTCOLUMNA(0x1061, LVCF_TEXT|LVCF_WIDTH) 插列后，
 * 用 SendMessageW 发 HDM_GETITEMW 读回，打印 WCHAR hex，判断存储是否正确 */
#include <windows.h>
#include <stdio.h>
#include <string.h>
#include "src/patches.h"

#define LVM_INSERTCOLUMNA 0x1061
#define HDM_GETITEMW      0x120B
#define HDI_TEXT_MASK     0x0002

/* tcc 头缺 HDITEMW：字段偏移与 HDITEM 一致，pszText 为 WCHAR* */
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
    LVCOLUMNA lc;
    HDITEMW_T hdiW;
    WCHAR wbuf[64];
    int i, j;
    FILE* f = fopen("hdrtest9.txt", "w");
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

    /* 插 6 列：真实 LVCF_TEXT=0x0004, LVCF_WIDTH=0x0002, LVCF_SUBITEM=0x0008 */
    {
        static const char* t[6] = { "Disk","Model","Bus","Size GB","Free GB","Status" };
        for (i = 0; i < 6; i++) {
            memset(&lc, 0, sizeof(lc));
            lc.mask = 0x0004 | 0x0002 | 0x0008;
            lc.cx = 80;
            lc.pszText = (char*)t[i];
            lc.iSubItem = i;
            SendMessageA(lv, LVM_INSERTCOLUMNA, (WPARAM)i, (LPARAM)&lc);
        }
    }
    hdr = (HWND)SendMessageA(lv, LVM_GETHEADER, 0, 0);
    fprintf(f, "count=%d\n", (int)SendMessageA(hdr, HDM_GETITEMCOUNT, 0, 0));

    /* SendMessageW + HDITEMW 读回 */
    for (i = 0; i < 6; i++) {
        memset(&hdiW, 0, sizeof(hdiW));
        memset(wbuf, 0, sizeof(wbuf));
        hdiW.mask = HDI_TEXT_MASK;
        hdiW.pszText = wbuf;
        hdiW.cchTextMax = 64;
        LRESULT ret = SendMessageW(hdr, HDM_GETITEMW, (WPARAM)i, (LPARAM)&hdiW);
        fprintf(f, "col%d ret=%ld: \"%ls\" hex:", i, (long)ret, wbuf);
        for (j = 0; j < 16 && wbuf[j]; j++) fprintf(f, " %04X", wbuf[j]);
        fprintf(f, "\n");
    }

    fclose(f);
    return 0;
}
