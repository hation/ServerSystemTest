/* msgtest5.c - 甄别 0x1001 语义 + SETITEMTEXTA 判别（用 col0 主文本做判别） */
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
typedef struct { UINT mask; int iItem; int iSubItem; UINT state; UINT stateMask; LPCWSTR pszText; int cchTextMax; int iImage; LPARAM lParam; int iIndent; int iGroupId; UINT cColumns; UINT* puColumns; int* piColFmt; int iGroup; } LVITEMW_T;

#define LVIF_TEXT 0x0001
#define LVM_GETHEADER (0x1000 + 31)
typedef struct { DWORD dwSize; DWORD dwICC; } ICCEX;
extern BOOL WINAPI InitCommonControlsEx(const ICCEX* picc);

static HWND mk(HWND parent)
{
    ICCEX icc; icc.dwSize = sizeof(icc); icc.dwICC = 1;
    InitCommonControlsEx(&icc);
    return CreateWindowExA(0, "SysListView32", "", WS_CHILD | WS_VISIBLE | 1,
                          0, 0, 300, 200, parent, NULL, GetModuleHandleA(NULL), NULL);
}
static int cols(HWND lv)
{
    HWND hdr = (HWND)SendMessageA(lv, LVM_GETHEADER, 0, 0);
    return hdr ? (int)SendMessageA(hdr, 0x1200, 0, 0) : -1;
}
static void addcol(HWND lv, const char* t)
{
    LVCOLUMN_T lc;
    memset(&lc, 0, sizeof(lc)); lc.mask = 0x1|0x2|0x8; lc.cx = 100; lc.pszText = (char*)t; lc.iSubItem = 0;
    SendMessageA(lv, 0x1061, 0, (LPARAM)&lc);
}
static void addrow(HWND lv, const char* c0)
{
    LVITEM_T it;
    memset(&it, 0, sizeof(it)); it.mask = LVIF_TEXT; it.iItem = 0; it.iSubItem = 0; it.pszText = (char*)c0;
    SendMessageA(lv, 0x1007, 0, (LPARAM)&it);
}
static void readcell(HWND lv, int row, int col, char* buf, int n)
{
    LVITEM_T it;
    memset(buf, 0, n);
    memset(&it, 0, sizeof(it)); it.mask = LVIF_TEXT; it.iItem = row; it.iSubItem = col;
    it.pszText = buf; it.cchTextMax = n;
    SendMessageA(lv, 0x102D, (WPARAM)row, (LPARAM)&it);
}

int main(void)
{
    HWND parent = GetDesktopWindow();

    /* 1) 0x1001 语义：传 COLORREF=0x00FF00，读 GETBKCOLOR(0x1000) */
    {
        HWND lv = mk(parent);
        LRESULT r0, r1;
        r0 = SendMessageA(lv, 0x1000, 0, 0);
        SendMessageA(lv, 0x1001, 0, (LPARAM)0x00FF00);
        r1 = SendMessageA(lv, 0x1000, 0, 0);
        printf("1) bkcolor before=0x%lX after set@0x1001=0xFF00 -> 0x%lX  (若 0x1001 是 SETBKCOLOR 则 after=0xFF00)\n",
               (unsigned long)r0, (unsigned long)r1);
        DestroyWindow(lv);
    }

    /* 2) SETITEMTEXTA 判别：col0 主文本 */
    {
        HWND lv = mk(parent);
        char buf[64];
        LVITEM_T it;
        static const int cands[] = { 0x102D, 0x102E, 0x102F, 0x1030, 0x102C, 0x102B, 0x102A, 0x1029, 0x1028 };
        int k;
        addcol(lv, "H");
        addrow(lv, "ROW0");
        for (k = 0; k < 9; k++) {
            memset(&it, 0, sizeof(it));
            it.mask = LVIF_TEXT; it.iItem = 0; it.iSubItem = 0; it.pszText = "NEW0";
            SendMessageA(lv, (UINT)cands[k], 0, (LPARAM)&it);
            readcell(lv, 0, 0, buf, sizeof(buf));
            printf("2) set col0 via 0x%X -> read=\"%s\" %s\n",
                   cands[k], buf, strcmp(buf, "NEW0") == 0 ? "<== 命中 SETITEMTEXTA" : "");
        }
        DestroyWindow(lv);
    }

    /* 3) 两列下子列 SETITEMTEXTA */
    {
        HWND lv = mk(parent);
        char buf[64];
        LVITEM_T it;
        addcol(lv, "H0"); addcol(lv, "H1");
        addrow(lv, "ROW0");
        memset(&it, 0, sizeof(it));
        it.mask = LVIF_TEXT; it.iItem = 0; it.iSubItem = 1; it.pszText = "CAND";
        SendMessageA(lv, 0x102E, 0, (LPARAM)&it);
        readcell(lv, 0, 1, buf, sizeof(buf));
        printf("3) 两列下 set subitem1 via 0x102E -> read=\"%s\"\n", buf);
        DestroyWindow(lv);
    }

    /* 4) W 消息跨读：SETITEMTEXTW@0x1074 后用 A/W 分别读 */
    {
        HWND lv = mk(parent);
        char buf[64];
        wchar_t wbuf[64];
        LVITEMW_T itw;
        LVITEM_T it;
        addcol(lv, "H"); addrow(lv, "ROW0");
        memset(&itw, 0, sizeof(itw));
        itw.mask = LVIF_TEXT; itw.iItem = 0; itw.iSubItem = 0; itw.pszText = L"WIDE0";
        SendMessageW(lv, 0x1074, 0, (LPARAM)&itw);
        readcell(lv, 0, 0, buf, sizeof(buf));
        printf("4) setW@0x1074 col0 -> readA=\"%s\"\n", buf);
        memset(wbuf, 0, sizeof(wbuf));
        memset(&itw, 0, sizeof(itw));
        itw.mask = LVIF_TEXT; itw.iItem = 0; itw.iSubItem = 0; itw.pszText = wbuf; itw.cchTextMax = 63;
        SendMessageW(lv, 0x1073, 0, (LPARAM)&itw);
        printf("4) setW@0x1074 col0 -> readW=\"%s\"\n", wbuf);
        DestroyWindow(lv);
    }

    printf("== done ==\n");
    return 0;
}
