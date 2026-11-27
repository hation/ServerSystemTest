/* hdrtest5.c - 分离插入端/读回端问题：
 * 独立 SysHeader32，分别用 HDM_INSERTITEMA(0x1202, mask=0x0004) 与
 * HDM_INSERTITEMW(0x120A, mask=0x0004) 插列，再用 0x1203/0x120B 读回。 */
#include <windows.h>
#include <stdio.h>
#include <string.h>
#include "src/patches.h"

#define HDM_INSERTITEMA 0x1202
#define HDM_INSERTITEMW 0x120A
#define HDM_GETITEMW    0x120B
#define HDI_TEXT_4      0x0004

int main(void)
{
    INITCOMMONCONTROLSEX icc;
    HWND top, hdr;
    HDITEM hdi;
    char bufA[256];
    WCHAR bufW[256];
    int cnt;
    FILE* f = fopen("hdrtest5.txt", "w");
    if (!f) return 1;

    memset(&icc, 0, sizeof(icc));
    icc.dwSize = sizeof(icc);
    icc.dwICC  = ICC_LISTVIEW_CLASSES;
    if (!InitCommonControlsEx(&icc)) { fprintf(f, "ICC_FAIL\n"); fclose(f); return 1; }
    top = CreateWindowExA(0, "STATIC", "t", WS_OVERLAPPED, 0, 0, 500, 300,
                          NULL, NULL, GetModuleHandleA(NULL), NULL);
    hdr = CreateWindowExA(0, "SysHeader32", "h", WS_CHILD | WS_VISIBLE,
                          0, 0, 500, 60, top, NULL, GetModuleHandleA(NULL), NULL);
    if (!hdr) { fprintf(f, "HDR_FAIL\n"); fclose(f); return 1; }

    /* 场景A：HDM_INSERTITEMA（ANSI 结构，mask=0x0004） */
    memset(&hdi, 0, sizeof(hdi));
    hdi.mask = HDI_TEXT_4;
    hdi.pszText = (char*)"Disk";
    fprintf(f, "A: INSERTITEMA(0x1202) ret=%ld count=%d\n",
            (long)SendMessageA(hdr, HDM_INSERTITEMA, 0, (LPARAM)&hdi),
            (int)SendMessageA(hdr, HDM_GETITEMCOUNT, 0, 0));
    memset(&hdi, 0, sizeof(hdi)); memset(bufA, 0, sizeof(bufA));
    hdi.mask = HDI_TEXT_4; hdi.pszText = bufA; hdi.cchTextMax = sizeof(bufA);
    fprintf(f, "A: GETITEMA(0x1203) ret=%ld buf=\"%s\"\n",
            (long)SendMessageA(hdr, HDM_GETITEMA, 0, (LPARAM)&hdi), bufA);
    memset(&hdi, 0, sizeof(hdi)); memset(bufW, 0, sizeof(bufW));
    hdi.mask = HDI_TEXT_4; hdi.pszText = (LPCSTR)bufW; hdi.cchTextMax = 128;
    fprintf(f, "A: GETITEMW(0x120B) ret=%ld buf=\"%ls\"\n",
            (long)SendMessageA(hdr, HDM_GETITEMW, 0, (LPARAM)&hdi), bufW);

    /* 场景B：HDM_INSERTITEMW（Unicode 结构，mask=0x0004） */
    memset(&hdi, 0, sizeof(hdi));
    hdi.mask = HDI_TEXT_4;
    hdi.pszText = (LPCSTR)L"Model";
    fprintf(f, "B: INSERTITEMW(0x120A) ret=%ld count=%d\n",
            (long)SendMessageA(hdr, HDM_INSERTITEMW, 1, (LPARAM)&hdi),
            (int)SendMessageA(hdr, HDM_GETITEMCOUNT, 0, 0));
    memset(&hdi, 0, sizeof(hdi)); memset(bufA, 0, sizeof(bufA));
    hdi.mask = HDI_TEXT_4; hdi.pszText = bufA; hdi.cchTextMax = sizeof(bufA);
    fprintf(f, "B: GETITEMA(0x1203) col1 ret=%ld buf=\"%s\"\n",
            (long)SendMessageA(hdr, HDM_GETITEMA, 1, (LPARAM)&hdi), bufA);
    memset(&hdi, 0, sizeof(hdi)); memset(bufW, 0, sizeof(bufW));
    hdi.mask = HDI_TEXT_4; hdi.pszText = (LPCSTR)bufW; hdi.cchTextMax = 128;
    fprintf(f, "B: GETITEMW(0x120B) col1 ret=%ld buf=\"%ls\"\n",
            (long)SendMessageA(hdr, HDM_GETITEMW, 1, (LPARAM)&hdi), bufW);

    /* 场景C：HDM_GETITEMA 不带 mask 直接读（看看是否填 fmt 等） */
    memset(&hdi, 0, sizeof(hdi));
    hdi.mask = HDI_TEXT_4 | 0x0008;   /* TEXT|FORMAT */
    hdi.pszText = bufA; hdi.cchTextMax = sizeof(bufA);
    fprintf(f, "C: GETITEMA(TEXT|FMT) col0 ret=%ld buf=\"%s\" fmt=%d\n",
            (long)SendMessageA(hdr, HDM_GETITEMA, 0, (LPARAM)&hdi), bufA, hdi.fmt);

    fclose(f);
    return 0;
}
