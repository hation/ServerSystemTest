/* hdrtest7.c - 找出真实 HDI_TEXT 值：0x120A 插入时用不同 mask，读回看哪个 mask 能取回文本 */
#include <windows.h>
#include <stdio.h>
#include <string.h>
#include "src/patches.h"

#define HDM_INSERT 0x120A
#define HDM_GETA   0x1203
#define HDM_GETW   0x120B

int main(void)
{
    INITCOMMONCONTROLSEX icc;
    HWND top, hdr;
    HDITEM hdi;
    char bufA[256];
    WCHAR bufW[256];
    int mask, i;
    FILE* f = fopen("hdrtest7.txt", "w");
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

    /* 插入 4 列，mask 分别为 0x0001,0x0002,0x0004,0x0008，文本 "T1".."T4" */
    for (i = 0; i < 4; i++) {
        char t[8];
        memset(&hdi, 0, sizeof(hdi));
        hdi.mask = 1u << i;
        sprintf(t, "T%d", i + 1);
        hdi.pszText = t;
        fprintf(f, "insert col%d mask=0x%04X ret=%ld count=%d\n", i, 1u << i,
                (long)SendMessageA(hdr, HDM_INSERT, i, (LPARAM)&hdi),
                (int)SendMessageA(hdr, HDM_GETITEMCOUNT, 0, 0));
    }

    /* 读回：每种 mask 试读每列，看哪种 mask 组合能读出文本 */
    for (mask = 1; mask <= 8; mask <<= 1) {
        for (i = 0; i < 4; i++) {
            memset(&hdi, 0, sizeof(hdi)); memset(bufA, 0, sizeof(bufA));
            hdi.mask = (UINT)mask; hdi.pszText = bufA; hdi.cchTextMax = sizeof(bufA);
            SendMessageA(hdr, HDM_GETA, i, (LPARAM)&hdi);
            fprintf(f, "GETA mask=0x%04X col%d = \"%s\"\n", mask, i, bufA);
        }
    }
    /* W 读回（mask=0x0004） */
    for (i = 0; i < 4; i++) {
        memset(&hdi, 0, sizeof(hdi)); memset(bufW, 0, sizeof(bufW));
        hdi.mask = 0x0004; hdi.pszText = (LPCSTR)bufW; hdi.cchTextMax = 128;
        SendMessageA(hdr, HDM_GETW, i, (LPARAM)&hdi);
        fprintf(f, "GETW mask=0x0004 col%d = \"%ls\"\n", i, bufW);
    }

    fclose(f);
    return 0;
}
