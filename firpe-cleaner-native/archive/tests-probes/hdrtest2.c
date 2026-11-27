/* hdrtest2.c - 子进程隔离探测：单个候选消息值 + 单种 lParam 语义。
 * 用法: hdrtest2.exe <msgHex> <mode> <outfile>
 *   mode=0: 颜色写语义 lParam=COLORREF
 *   mode=1: 指针语义 lParam=&HDITEM（有效栈结构）
 * 每次启动新建 header+1列，执行一次 SendMessage，结果写 outfile（追加）。 */
#include <windows.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include "src/patches.h"

#ifndef HDS_BUTTONS
#define HDS_BUTTONS 0x0002
#endif
#ifndef HDM_INSERTITEMA
#define HDM_INSERTITEMA (HDM_FIRST + 0x02)
#endif

int main(int argc, char** argv)
{
    INITCOMMONCONTROLSEX icc;
    HWND top, hdr;
    FILE* f;
    UINT msg;
    int mode;
    LRESULT ret;
    HDITEM hdi;
    char buf[128];
    COLORREF tc;
    int cnt;

    if (argc < 4) return 2;
    msg = (UINT)strtoul(argv[1], NULL, 16);
    mode = atoi(argv[2]);
    f = fopen(argv[3], "a");
    if (!f) return 3;

    memset(&icc, 0, sizeof(icc));
    icc.dwSize = sizeof(icc);
    icc.dwICC  = ICC_LISTVIEW_CLASSES;
    if (!InitCommonControlsEx(&icc)) { fprintf(f, "msg=0x%04X mode=%d ICC_FAIL\n", msg, mode); fclose(f); return 1; }

    top = CreateWindowExA(0, "STATIC", "t", WS_OVERLAPPED, 0, 0, 400, 300,
                          NULL, NULL, GetModuleHandleA(NULL), NULL);
    hdr = CreateWindowExA(0, "SysHeader32", "h",
                          WS_CHILD | WS_VISIBLE | HDS_BUTTONS, 0, 0, 400, 60,
                          top, NULL, GetModuleHandleA(NULL), NULL);
    if (!hdr) { fprintf(f, "msg=0x%04X mode=%d CREATE_FAIL\n", msg, mode); fclose(f); return 1; }
    memset(&hdi, 0, sizeof(hdi));
    hdi.mask = HDI_TEXT;
    hdi.pszText = (char*)"Col0";
    SendMessageA(hdr, HDM_INSERTITEMA, 0, (LPARAM)&hdi);
    cnt = (int)SendMessageA(hdr, HDM_GETITEMCOUNT, 0, 0);

    memset(&hdi, 0, sizeof(hdi));
    hdi.mask = HDI_TEXT;
    hdi.pszText = buf;
    hdi.cchTextMax = sizeof(buf);

    fprintf(f, "msg=0x%04X mode=%d count=%d", msg, mode, cnt);
    if (mode == 0) {
        ret = SendMessageA(hdr, msg, 0, (LPARAM)RGB(200, 100, 50));   /* 0x00C86432 */
        tc = (COLORREF)SendMessageA(hdr, HDM_GETTEXTCOLOR, 0, 0);
        fprintf(f, " ret=%ld textcolor_after=0x%08lX", (long)ret, (unsigned long)tc);
        /* 试 GETBKCOLOR 候选 0x120C 读回（只读，安全） */
        fprintf(f, " bkcolor_0x120C=0x%08lX", (unsigned long)(COLORREF)SendMessageA(hdr, 0x120C, 0, 0));
    } else {
        ret = SendMessageA(hdr, msg, 0, (LPARAM)&hdi);
        fprintf(f, " ret=%ld buf=\"%s\" count_after=%d", (long)ret, buf,
                (int)SendMessageA(hdr, HDM_GETITEMCOUNT, 0, 0));
    }
    fprintf(f, "\n");
    fclose(f);
    DestroyWindow(hdr);
    DestroyWindow(top);
    return 0;
}
