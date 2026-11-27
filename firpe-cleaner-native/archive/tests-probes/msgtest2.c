/* msgtest2.c - 最小化权威消息号验证（避免全扫描崩溃）
 * 验证 4 组关键消息在真实 comctl32 上的行为：
 *   1) 0x1001 是否 LVM_INSERTCOLUMNA（列数 0->1）
 *   2) 0x102D vs 0x102E 谁是 LVM_SETITEMTEXTA（读回子列文本）
 *   3) 0x102D 读主列文本（GETITEMTEXTA）
 *   4) 带 CHECKBOXES 时 0x102B/0x102C 勾选设置/读取
 */
#include <windows.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

typedef struct {
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

typedef struct {
    UINT   mask;
    int    fmt;
    int    cx;
    LPCSTR pszText;
    int    cchTextMax;
    int    iSubItem;
    int    iImage;
    int    iOrder;
} LVCOLUMN_T;

#define LVIF_TEXT 0x0001
#define LVIF_STATE 0x0008
#define LVIS_STATEIMAGEMASK 0xF000
#define INDEXTOSTATEIMAGEMASK(i) ((i) << 12)
#define LVS_EX_CHECKBOXES 0x4

typedef struct { DWORD dwSize; DWORD dwICC; } ICCEX;
extern BOOL WINAPI InitCommonControlsEx(const ICCEX* picc);

static HWND make_listview(HWND parent, int withCheckbox)
{
    ICCEX icc;
    HWND lv;
    icc.dwSize = sizeof(icc);
    icc.dwICC = 1;
    InitCommonControlsEx(&icc);
    lv = CreateWindowExA(0, "SysListView32", "",
        WS_CHILD | WS_VISIBLE | 0x0001 /* LVS_REPORT */,
        0, 0, 300, 200, parent, NULL, GetModuleHandleA(NULL), NULL);
    if (withCheckbox)
        SendMessageA(lv, 0x1036 /* SETEXTENDED */, 0, (LPARAM)LVS_EX_CHECKBOXES);
    return lv;
}

static int header_cols(HWND lv)
{
    HWND hdr = (HWND)SendMessageA(lv, 0x101F /* LVM_GETHEADER */, 0, 0);
    if (!hdr) return -1;
    return (int)SendMessageA(hdr, 0x1200 /* HDM_GETITEMCOUNT */, 0, 0);
}

static void add_col(HWND lv, int msg, const char* title)
{
    LVCOLUMN_T lc;
    memset(&lc, 0, sizeof(lc));
    lc.mask = 0x0001 | 0x0002 | 0x0008;   /* LVCF_TEXT|WIDTH|SUBITEM */
    lc.cx = 100;
    lc.pszText = (char*)title;
    lc.iSubItem = 0;
    SendMessageA(lv, (UINT)msg, 0, (LPARAM)&lc);
}

static void add_row(HWND lv, const char* col0)
{
    LVITEM_T it;
    memset(&it, 0, sizeof(it));
    it.mask = LVIF_TEXT;
    it.iItem = 0;
    it.iSubItem = 0;
    it.pszText = (char*)col0;
    SendMessageA(lv, 0x1007 /* LVM_INSERTITEMA */, 0, (LPARAM)&it);
}

static void read_cell(HWND lv, int row, int col, char* buf, int buflen)
{
    LVITEM_T it;
    memset(buf, 0, buflen);
    memset(&it, 0, sizeof(it));
    it.mask = LVIF_TEXT;
    it.iItem = row;
    it.iSubItem = col;
    it.pszText = buf;
    it.cchTextMax = buflen;
    SendMessageA(lv, 0x102D /* LVM_GETITEMTEXTA */, (WPARAM)row, (LPARAM)&it);
}

int main(void)
{
    HWND parent = GetDesktopWindow();

    /* 1) 0x1001 = INSERTCOLUMNA? */
    {
        HWND lv = make_listview(parent, 0);
        add_col(lv, 0x1001, "H");
        printf("1) insert-col @0x1001 -> header cols = %d (期望 1)\n", header_cols(lv));
        DestroyWindow(lv);
    }

    /* 2) SETITEMTEXTA: 0x102D vs 0x102E */
    {
        HWND lv = make_listview(parent, 0);
        char buf[64];
        add_col(lv, 0x1001, "H");
        add_row(lv, "ROW0");
        printf("2a) read col0 via 0x102D: \"%s\"\n", (read_cell(lv, 0, 0, buf, sizeof(buf)), buf));

        /* 候选 A：0x102E */
        {
            LVITEM_T it;
            memset(&it, 0, sizeof(it));
            it.mask = LVIF_TEXT;
            it.iItem = 0;
            it.iSubItem = 1;
            it.pszText = "YYY";
            SendMessageA(lv, 0x102E, 0, (LPARAM)&it);
            read_cell(lv, 0, 1, buf, sizeof(buf));
            printf("2b) set-subitem @0x102E -> col1=\"%s\" (期望 YYY)\n", buf);
        }
        /* 候选 B：0x102D（patches.h 当前值） */
        {
            LVITEM_T it;
            memset(&it, 0, sizeof(it));
            it.mask = LVIF_TEXT;
            it.iItem = 0;
            it.iSubItem = 1;
            it.pszText = "ZZZ";
            SendMessageA(lv, 0x102D, 0, (LPARAM)&it);
            read_cell(lv, 0, 1, buf, sizeof(buf));
            printf("2c) set-subitem @0x102D -> col1=\"%s\" (期望 ZZZ 则 0x102D 是 SET)\n", buf);
        }
        /* 候选 C：0x102F */
        {
            LVITEM_T it;
            memset(&it, 0, sizeof(it));
            it.mask = LVIF_TEXT;
            it.iItem = 0;
            it.iSubItem = 1;
            it.pszText = "WWW";
            SendMessageA(lv, 0x102F, 0, (LPARAM)&it);
            read_cell(lv, 0, 1, buf, sizeof(buf));
            printf("2d) set-subitem @0x102F -> col1=\"%s\"\n", buf);
        }
        DestroyWindow(lv);
    }

    /* 3) checkbox: SETITEMSTATE@0x102B -> GETITEMSTATE@0x102C */
    {
        HWND lv = make_listview(parent, 1);
        LVITEM_T it;
        LRESULT st;
        add_col(lv, 0x1001, "H");
        add_row(lv, "ROW0");
        memset(&it, 0, sizeof(it));
        it.mask = LVIF_STATE;
        it.stateMask = LVIS_STATEIMAGEMASK;
        it.state = INDEXTOSTATEIMAGEMASK(2);
        SendMessageA(lv, 0x102B, 0, (LPARAM)&it);
        st = SendMessageA(lv, 0x102C, 0, (LPARAM)LVIS_STATEIMAGEMASK);
        printf("3) setstate@0x102B -> getstate@0x102C = 0x%lX (0x2000=checked)\n",
               (unsigned long)st);
        DestroyWindow(lv);
    }

    printf("== done ==\n");
    return 0;
}
