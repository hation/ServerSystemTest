/* hdrtest6.c - 决定性矩阵：独立 SysHeader32
 * 1) 0x120A + ANSI 文本插入，0x1203/0x120B 读回
 * 2) 0x120A + W 文本插入，0x1203/0x120B 读回 */
#include <windows.h>
#include <stdio.h>
#include <string.h>
#include "src/patches.h"

#define HDM_INSERT 0x120A
#define HDM_GETA   0x1203
#define HDM_GETW   0x120B
#define HDI_TEXT_4 0x0004

int main(void)
{
    INITCOMMONCONTROLSEX icc;
    HWND top, hdr;
    HDITEM hdi;
    char bufA[256];
    WCHAR bufW[256];
    int i;
    FILE* f = fopen("hdrtest6.txt", "w");
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

    /* 1) 0x120A + ANSI "Disk" */
    memset(&hdi, 0, sizeof(hdi));
    hdi.mask = HDI_TEXT_4; hdi.pszText = (char*)"Disk";
    fprintf(f, "1) INSERT(0x120A, ANSI) ret=%ld count=%d\n",
            (long)SendMessageA(hdr, HDM_INSERT, 0, (LPARAM)&hdi),
            (int)SendMessageA(hdr, HDM_GETITEMCOUNT, 0, 0));
    memset(&hdi, 0, sizeof(hdi)); memset(bufA, 0, sizeof(bufA));
    hdi.mask = HDI_TEXT_4; hdi.pszText = bufA; hdi.cchTextMax = sizeof(bufA);
    fprintf(f, "1) GETA(0x1203) ret=%ld buf=\"%s\"\n",
            (long)SendMessageA(hdr, HDM_GETA, 0, (LPARAM)&hdi), bufA);
    memset(&hdi, 0, sizeof(hdi)); memset(bufW, 0, sizeof(bufW));
    hdi.mask = HDI_TEXT_4; hdi.pszText = (LPCSTR)bufW; hdi.cchTextMax = 128;
    fprintf(f, "1) GETW(0x120B) ret=%ld bufW=\"%ls\"\n",
            (long)SendMessageA(hdr, HDM_GETW, 0, (LPARAM)&hdi), bufW);

    /* 2) 0x120A + W "Model" */
    memset(&hdi, 0, sizeof(hdi));
    hdi.mask = HDI_TEXT_4; hdi.pszText = (LPCSTR)L"Model";
    fprintf(f, "2) INSERT(0x120A, W) ret=%ld count=%d\n",
            (long)SendMessageA(hdr, HDM_INSERT, 1, (LPARAM)&hdi),
            (int)SendMessageA(hdr, HDM_GETITEMCOUNT, 0, 0));
    memset(&hdi, 0, sizeof(hdi)); memset(bufA, 0, sizeof(bufA));
    hdi.mask = HDI_TEXT_4; hdi.pszText = bufA; hdi.cchTextMax = sizeof(bufA);
    fprintf(f, "2) GETA(0x1203) col1 ret=%ld buf=\"%s\"\n",
            (long)SendMessageA(hdr, HDM_GETA, 1, (LPARAM)&hdi), bufA);
    memset(&hdi, 0, sizeof(hdi)); memset(bufW, 0, sizeof(bufW));
    hdi.mask = HDI_TEXT_4; hdi.pszText = (LPCSTR)bufW; hdi.cchTextMax = 128;
    fprintf(f, "2) GETW(0x120B) col1 ret=%ld bufW=\"%ls\"\n",
            (long)SendMessageA(hdr, HDM_GETW, 1, (LPARAM)&hdi), bufW);

    /* 3) 再插 4 列验证 ListView 风格 6 列（0x120A + ANSI） */
    {
        static const char* t[4] = { "Bus","Size GB","Free GB","Status" };
        for (i = 0; i < 4; i++) {
            memset(&hdi, 0, sizeof(hdi));
            hdi.mask = HDI_TEXT_4; hdi.pszText = (char*)t[i];
            SendMessageA(hdr, HDM_INSERT, 2 + i, (LPARAM)&hdi);
        }
        fprintf(f, "3) final count=%d\n", (int)SendMessageA(hdr, HDM_GETITEMCOUNT, 0, 0));
        for (i = 0; i < 6; i++) {
            memset(&hdi, 0, sizeof(hdi)); memset(bufA, 0, sizeof(bufA));
            hdi.mask = HDI_TEXT_4; hdi.pszText = bufA; hdi.cchTextMax = sizeof(bufA);
            SendMessageA(hdr, HDM_GETA, i, (LPARAM)&hdi);
            fprintf(f, "3) GETA col%d = \"%s\"\n", i, bufA);
        }
    }

    fclose(f);
    return 0;
}
