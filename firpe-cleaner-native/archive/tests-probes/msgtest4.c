/* msgtest4.c - 聚焦验证（x86/x64 双跑）：
 *  A) 列插入：0x1001(A结构) vs 0x1061(A结构) vs 0x1061(W结构)
 *  B) SETITEMTEXT：0x102E(A) / 0x1074(W) 在有列的前提下验证
 *  C) GETITEMTEXTW 0x1073 读回验证
 */
#include <windows.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

typedef struct {
    UINT   mask; int iItem; int iSubItem; UINT state; UINT stateMask;
    LPCSTR pszText; int cchTextMax; int iImage; LPARAM lParam;
    int iIndent; int iGroupId; UINT cColumns; UINT* puColumns; int* piColFmt; int iGroup;
} LVITEM_T;
typedef struct { UINT mask; int fmt; int cx; LPCSTR pszText; int cchTextMax; int iSubItem; int iImage; int iOrder; } LVCOLUMN_T;
typedef struct { UINT mask; int fmt; int cx; LPCWSTR pszText; int cchTextMax; int iSubItem; int iImage; int iOrder; int cxMin; int cxDefault; int cxIdeal; } LVCOLUMNW_T;
typedef struct { UINT mask; int iItem; int iSubItem; UINT state; UINT stateMask; LPCWSTR pszText; int cchTextMax; int iImage; LPARAM lParam; int iIndent; int iGroupId; UINT cColumns; UINT* puColumns; int* piColFmt; int iGroup; } LVITEMW_T;

#define LVIF_TEXT 0x0001
#define LVM_GETHEADER (0x1000 + 31)
typedef struct { DWORD dwSize; DWORD dwICC; } ICCEX;
extern BOOL WINAPI InitCommonControlsEx(const ICCEX* picc);

static HWND mk(HWND parent)
{
    ICCEX icc; icc.dwSize = sizeof(icc); icc.dwICC = 1;
    InitCommonControlsEx(&icc);
    return CreateWindowExA(0, "SysListView32", "", WS_CHILD | WS_VISIBLE | 1 /*REPORT*/,
                          0, 0, 300, 200, parent, NULL, GetModuleHandleA(NULL), NULL);
}
static int cols(HWND lv)
{
    HWND hdr = (HWND)SendMessageA(lv, LVM_GETHEADER, 0, 0);
    return hdr ? (int)SendMessageA(hdr, 0x1200, 0, 0) : -1;
}

int main(void)
{
    HWND parent = GetDesktopWindow();
    printf("ptr=%zu\n", sizeof(void*));

    /* A) 列插入三方案 */
    {
        HWND lv = mk(parent); LVCOLUMN_T lc;
        memset(&lc, 0, sizeof(lc)); lc.mask = 0x1|0x2|0x8; lc.cx = 100; lc.pszText = "H"; lc.iSubItem = 0;
        SendMessageA(lv, 0x1001, 0, (LPARAM)&lc);
        printf("A1) 0x1001 + A结构 -> cols=%d\n", cols(lv)); DestroyWindow(lv);
    }
    {
        HWND lv = mk(parent); LVCOLUMN_T lc;
        memset(&lc, 0, sizeof(lc)); lc.mask = 0x1|0x2|0x8; lc.cx = 100; lc.pszText = "H"; lc.iSubItem = 0;
        SendMessageA(lv, 0x1061, 0, (LPARAM)&lc);
        printf("A2) 0x1061 + A结构 -> cols=%d\n", cols(lv)); DestroyWindow(lv);
    }
    {
        HWND lv = mk(parent); LVCOLUMNW_T lc; wchar_t wt[] = L"H";
        memset(&lc, 0, sizeof(lc)); lc.mask = 0x1|0x2|0x8; lc.cx = 100; lc.pszText = wt; lc.iSubItem = 0;
        SendMessageW(lv, 0x1061, 0, (LPARAM)&lc);
        printf("A3) 0x1061 + W结构 -> cols=%d\n", cols(lv)); DestroyWindow(lv);
    }

    /* B) SETITEMTEXT：先用 0x1061+W结构建列、0x1007 插行 */
    {
        HWND lv = mk(parent);
        LVCOLUMNW_T lc; wchar_t wt[] = L"H";
        LVITEM_T it; char buf[64];
        memset(&lc, 0, sizeof(lc)); lc.mask = 0x1|0x2|0x8; lc.cx = 100; lc.pszText = wt; lc.iSubItem = 0;
        SendMessageW(lv, 0x1061, 0, (LPARAM)&lc);
        memset(&it, 0, sizeof(it)); it.mask = LVIF_TEXT; it.iItem = 0; it.iSubItem = 0; it.pszText = "ROW0";
        SendMessageA(lv, 0x1007, 0, (LPARAM)&it);
        printf("B0) cols=%d\n", cols(lv));

        /* ANSI SETITEMTEXTA 候选 0x102E */
        memset(&it, 0, sizeof(it)); it.mask = LVIF_TEXT; it.iItem = 0; it.iSubItem = 1; it.pszText = "CAND";
        SendMessageA(lv, 0x102E, 0, (LPARAM)&it);
        memset(buf, 0, sizeof(buf));
        memset(&it, 0, sizeof(it)); it.mask = LVIF_TEXT; it.iItem = 0; it.iSubItem = 1; it.pszText = buf; it.cchTextMax = sizeof(buf);
        SendMessageA(lv, 0x102D, 0, (LPARAM)&it);
        printf("B1) set@0x102E -> read@0x102D col1=\"%s\"\n", buf);

        /* W SETITEMTEXTW 候选 0x1074 */
        {
            LVITEMW_T itw; wchar_t wbuf[64]; wchar_t wsrc[] = L"WIDE";
            memset(&itw, 0, sizeof(itw)); itw.mask = LVIF_TEXT; itw.iItem = 0; itw.iSubItem = 1; itw.pszText = wsrc;
            SendMessageW(lv, 0x1074, 0, (LPARAM)&itw);
            memset(wbuf, 0, sizeof(wbuf));
            memset(&itw, 0, sizeof(itw)); itw.mask = LVIF_TEXT; itw.iItem = 0; itw.iSubItem = 1; itw.pszText = wbuf; itw.cchTextMax = 63;
            SendMessageW(lv, 0x1073, 0, (LPARAM)&itw);
            printf("B2) set@0x1074(W) -> read@0x1073(W) col1=\"%s\"\n", wbuf);
        }
        DestroyWindow(lv);
    }

    printf("== done ==\n");
    return 0;
}
