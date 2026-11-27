/* msgtest3.c - 确定 LVM_INSERTCOLUMNA / LVM_SETITEMTEXTA 权威消息号
 * 经典区用 ANSI 结构，W 区(0x1060+)用宽字符结构。
 */
#include <windows.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

typedef struct {  /* LVITEMA 布局（已验证 == SDK） */
    UINT   mask;
    int    iItem;
    int    iSubItem;
    UINT   state;
    UINT   stateMask;
    LPCSTR pszText;
    int    cchTextMax;
    int    iImage;
    LPARAM lParam;
    int    iIndent;
    int    iGroupId;
    UINT   cColumns;
    UINT*  puColumns;
    int*   piColFmt;
    int    iGroup;
} LVITEM_T;

typedef struct {  /* LVCOLUMNA 布局 */
    UINT   mask;
    int    fmt;
    int    cx;
    LPCSTR pszText;
    int    cchTextMax;
    int    iSubItem;
    int    iImage;
    int    iOrder;
} LVCOLUMN_T;

typedef struct {  /* LVCOLUMNW 布局 */
    UINT    mask;
    int     fmt;
    int     cx;
    LPCWSTR pszText;
    int     cchTextMax;
    int     iSubItem;
    int     iImage;
    int     iOrder;
    int     cxMin;
    int     cxDefault;
    int     cxIdeal;
} LVCOLUMNW_T;

typedef struct {  /* LVITEMW 布局 */
    UINT   mask;
    int    iItem;
    int    iSubItem;
    UINT   state;
    UINT   stateMask;
    LPCWSTR pszText;
    int    cchTextMax;
    int    iImage;
    LPARAM lParam;
    int    iIndent;
    int    iGroupId;
    UINT   cColumns;
    UINT*  puColumns;
    int*   piColFmt;
    int    iGroup;
} LVITEMW_T;

#define LVIF_TEXT 0x0001
#define LVM_FIRST 0x1000
#define LVM_GETITEMCOUNT (LVM_FIRST + 4)
#define LVM_GETHEADER    (LVM_FIRST + 31)

typedef struct { DWORD dwSize; DWORD dwICC; } ICCEX;
extern BOOL WINAPI InitCommonControlsEx(const ICCEX* picc);

static HWND make_listview(HWND parent)
{
    ICCEX icc;
    icc.dwSize = sizeof(icc);
    icc.dwICC = 1;
    InitCommonControlsEx(&icc);
    return CreateWindowExA(0, "SysListView32", "",
        WS_CHILD | WS_VISIBLE | 0x0001 /* LVS_REPORT */,
        0, 0, 300, 200, parent, NULL, GetModuleHandleA(NULL), NULL);
}

static int header_cols(HWND lv)
{
    HWND hdr = (HWND)SendMessageA(lv, LVM_GETHEADER, 0, 0);
    if (!hdr) return -1;
    return (int)SendMessageA(hdr, 0x1200, 0, 0);
}

int main(void)
{
    HWND parent = GetDesktopWindow();
    int m, foundCol = -1;

    printf("== 找 LVM_INSERTCOLUMNA ==\n");
    for (m = 0x1000; m <= 0x100F; m++) {
        HWND lv = make_listview(parent);
        LVCOLUMN_T lc;
        memset(&lc, 0, sizeof(lc));
        lc.mask = 0x1 | 0x2 | 0x8;
        lc.cx = 100;
        lc.pszText = "H";
        lc.iSubItem = 0;
        SendMessageA(lv, (UINT)m, 0, (LPARAM)&lc);
        if (header_cols(lv) == 1) { printf("  ANSI 区命中: 0x%X (+%d)\n", m, m - LVM_FIRST); foundCol = m; }
        DestroyWindow(lv);
    }
    for (m = 0x1060; m <= 0x1078; m++) {
        HWND lv = make_listview(parent);
        LVCOLUMNW_T lc;
        wchar_t wt[] = L"H";
        memset(&lc, 0, sizeof(lc));
        lc.mask = 0x1 | 0x2 | 0x8;
        lc.cx = 100;
        lc.pszText = wt;
        lc.iSubItem = 0;
        SendMessageW(lv, (UINT)m, 0, (LPARAM)&lc);
        if (header_cols(lv) == 1) { printf("  W 区命中: 0x%X (+%d)\n", m, m - LVM_FIRST); if (foundCol < 0) foundCol = m; }
        DestroyWindow(lv);
    }
    if (foundCol < 0) { printf("  仍未找到\n"); return 1; }

    printf("== 用命中消息建列，验证 SETITEMTEXTA 候选 ==\n");
    {
        HWND lv = make_listview(parent);
        LVCOLUMN_T lc;
        LVITEM_T it;
        char buf[64];
        memset(&lc, 0, sizeof(lc));
        lc.mask = 0x1 | 0x2 | 0x8;
        lc.cx = 100;
        lc.pszText = "H";
        lc.iSubItem = 0;
        SendMessageA(lv, (UINT)foundCol, 0, (LPARAM)&lc);
        memset(&it, 0, sizeof(it));
        it.mask = LVIF_TEXT;
        it.iItem = 0;
        it.iSubItem = 0;
        it.pszText = "ROW0";
        SendMessageA(lv, 0x1007, 0, (LPARAM)&it);   /* INSERTITEMA */
        printf("  列数=%d\n", header_cols(lv));

        /* ANSI SETITEMTEXT 候选 */
        {
            static const int cands[] = { 0x102D, 0x102E, 0x102F, 0x1030, 0x102C, 0x102B, 0x102A, 0x1029, 0x1028 };
            int k;
            for (k = 0; k < 9; k++) {
                memset(&it, 0, sizeof(it));
                it.mask = LVIF_TEXT;
                it.iItem = 0;
                it.iSubItem = 1;
                it.pszText = "CAND";
                SendMessageA(lv, (UINT)cands[k], 0, (LPARAM)&it);
                memset(buf, 0, sizeof(buf));
                memset(&it, 0, sizeof(it));
                it.mask = LVIF_TEXT;
                it.iItem = 0;
                it.iSubItem = 1;
                it.pszText = buf;
                it.cchTextMax = sizeof(buf);
                SendMessageA(lv, 0x102D, 0, (LPARAM)&it);
                if (strcmp(buf, "CAND") == 0)
                    printf("  ANSI SETITEMTEXTA 命中: 0x%X (+%d)\n", cands[k], cands[k] - LVM_FIRST);
            }
        }
        /* W SETITEMTEXT 候选（0x1074=116 附近） */
        {
            static const int cands[] = { 0x1072, 0x1073, 0x1074, 0x1075, 0x1076 };
            int k;
            for (k = 0; k < 5; k++) {
                LVITEMW_T itw;
                wchar_t wbuf[64];
                wchar_t wsrc[] = L"WIDE";
                memset(&itw, 0, sizeof(itw));
                itw.mask = LVIF_TEXT;
                itw.iItem = 0;
                itw.iSubItem = 1;
                itw.pszText = wsrc;
                SendMessageW(lv, (UINT)cands[k], 0, (LPARAM)&itw);
                memset(wbuf, 0, sizeof(wbuf));
                memset(&itw, 0, sizeof(itw));
                itw.mask = LVIF_TEXT;
                itw.iItem = 0;
                itw.iSubItem = 1;
                itw.pszText = wbuf;
                itw.cchTextMax = 63;
                SendMessageW(lv, 0x1073 /* GETITEMTEXTW=115 */, 0, (LPARAM)&itw);
                if (wcsncmp(wbuf, L"WIDE", 4) == 0)
                    printf("  W SETITEMTEXTW 命中: 0x%X (+%d)\n", cands[k], cands[k] - LVM_FIRST);
            }
        }
        DestroyWindow(lv);
    }

    printf("== 验证 SETEXTENDED/GETEXTENDED ==\n");
    {
        HWND lv = make_listview(parent);
        LRESULT r;
        SendMessageA(lv, 0x1036, 0, (LPARAM)0x25);   /* 设 grid|checkbox|fullrow */
        r = SendMessageA(lv, 0x1037, 0, 0);
        printf("  set@0x1036=0x25 -> get@0x1037 = 0x%lX\n", (unsigned long)r);
        r = SendMessageA(lv, 0x1035, 0, 0);
        printf("  get@0x1035 = 0x%lX\n", (unsigned long)r);
        r = SendMessageA(lv, 0x1036, 0, 0);
        printf("  get@0x1036 = 0x%lX\n", (unsigned long)r);
        DestroyWindow(lv);
    }

    printf("== done ==\n");
    return 0;
}
