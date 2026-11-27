/* msgtest.c - 在本机系统上实证确定 ListView 消息号权威值
 * 方法：创建全新 ListView（report view），逐个候选消息号发送 LVCOLUMNA/LVITEM，
 * 观察实际效果，反推消息的真实语义。这是「系统行为」层面的证据，不依赖头文件。
 * 编译：TCC x86/x64，需 -luser32 -lgdi32 -lcomctl32(或用 .def)。
 */
#include <windows.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

/* 与 patches.h 相同布局的 LVITEMA / LVCOLUMNA（已验证 == SDK） */
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

#define LVM_FIRST 0x1000
#define LVM_GETITEMCOUNT    (LVM_FIRST + 4)
#define LVM_GETHEADER       (LVM_FIRST + 31)
#define LVM_GETITEMTEXTA    (LVM_FIRST + 45)
#define LVIF_TEXT 0x0001
#define LVIF_STATE 0x0008
#define LVIS_STATEIMAGEMASK 0xF000
#define INDEXTOSTATEIMAGEMASK(i) ((i) << 12)
#define HDM_GETITEMCOUNT 0x1200

typedef struct { DWORD dwSize; DWORD dwICC; } ICCEX;
extern BOOL WINAPI InitCommonControlsEx(const ICCEX* picc);

static HWND g_created;

static HWND make_listview(HWND parent)
{
    ICCEX icc;
    HWND lv;
    icc.dwSize = sizeof(icc);
    icc.dwICC = 1; /* ICC_LISTVIEW_CLASSES */
    InitCommonControlsEx(&icc);
    lv = CreateWindowExA(0, "SysListView32", "",
        WS_CHILD | WS_VISIBLE | 0x0001 /* LVS_REPORT */,
        0, 0, 300, 200, parent, NULL, GetModuleHandleA(NULL), NULL);
    return lv;
}

static int header_cols(HWND lv)
{
    HWND hdr = (HWND)SendMessageA(lv, LVM_GETHEADER, 0, 0);
    if (!hdr) return -1;
    return (int)SendMessageA(hdr, HDM_GETITEMCOUNT, 0, 0);
}

int main(void)
{
    HWND parent;
    int m;
    int foundInsertCol = -1;
    int foundSetText = -1;

    parent = GetDesktopWindow();   /* 测试用父窗口：桌面（子窗口必须有有效父窗口） */

    /* 1) 找 LVM_INSERTCOLUMNA：0x1000..0x1080 全扫，发 LVCOLUMNA 后列数==1 即命中 */
    printf("== sweep for LVM_INSERTCOLUMNA ==\n");
    for (m = 0x1000; m <= 0x1080; m++) {
        HWND lv = make_listview(parent);
        LVCOLUMN_T lc;
        int n;
        memset(&lc, 0, sizeof(lc));
        lc.mask = 0x0001 | 0x0002 | 0x0008;  /* LVCF_TEXT|LVCF_WIDTH|LVCF_SUBITEM */
        lc.cx = 100;
        lc.pszText = "H";
        lc.iSubItem = 0;
        SendMessageA(lv, (UINT)m, 0, (LPARAM)&lc);
        n = header_cols(lv);
        if (n == 1) {
            printf("  INSERTCOLUMNA candidate: 0x%X (+%d)\n", m, m - LVM_FIRST);
            if (foundInsertCol < 0) foundInsertCol = m;
        }
        DestroyWindow(lv);
    }
    if (foundInsertCol < 0) printf("  NOT FOUND\n");

    /* 2) 找 LVM_SETITEMTEXTA：先建 1 列 + 1 行，对候选消息发 LVITEM(pszText=YYY)，
     *    再读回子列文本（LVM_GETITEMTEXTA=0x102D），读到 YYY 即命中 */
    printf("== sweep for LVM_SETITEMTEXTA (GETITEMTEXTA=0x102D) ==\n");
    {
        /* 先验证 0x102D 读文本是否正常 */
        HWND lv = make_listview(parent);
        LVCOLUMN_T lc;
        LVITEM_T it;
        char buf[64];
        memset(&lc, 0, sizeof(lc));
        lc.mask = 0x0001 | 0x0002 | 0x0008;
        lc.cx = 100;
        lc.pszText = "H";
        lc.iSubItem = 0;
        SendMessageA(lv, (UINT)foundInsertCol, 0, (LPARAM)&lc);
        memset(&it, 0, sizeof(it));
        it.mask = 0x0001; /* LVIF_TEXT */
        it.iItem = 0;
        it.iSubItem = 0;
        it.pszText = "ROW0";
        SendMessageA(lv, 0x1007 /* 0x1000+7 */, 0, (LPARAM)&it);   /* LVM_INSERTITEMA */
        memset(buf, 0, sizeof(buf));
        memset(&it, 0, sizeof(it));
        it.mask = 0x0001;
        it.iItem = 0;
        it.iSubItem = 0;
        it.pszText = buf;
        it.cchTextMax = sizeof(buf);
        SendMessageA(lv, LVM_GETITEMTEXTA, 0, (LPARAM)&it);
        printf("  GETITEMTEXTA@0x102D reads col0: \"%s\"\n", buf);
        DestroyWindow(lv);
    }

    for (m = 0x1000; m <= 0x1080; m++) {
        HWND lv = make_listview(parent);
        LVCOLUMN_T lc;
        LVITEM_T it;
        char buf[64];
        int n;
        memset(&lc, 0, sizeof(lc));
        lc.mask = 0x0001 | 0x0002 | 0x0008;
        lc.cx = 100;
        lc.pszText = "H";
        lc.iSubItem = 0;
        SendMessageA(lv, (UINT)foundInsertCol, 0, (LPARAM)&lc);
        memset(&it, 0, sizeof(it));
        it.mask = 0x0001;
        it.iItem = 0;
        it.iSubItem = 0;
        it.pszText = "ROW0";
        SendMessageA(lv, 0x1007, 0, (LPARAM)&it);   /* LVM_INSERTITEMA */
        /* 候选 SETITEMTEXT：lParam=LVITEM(mask=TEXT, iSubItem=1, pszText=YYY) */
        memset(&it, 0, sizeof(it));
        it.mask = 0x0001;
        it.iItem = 0;
        it.iSubItem = 1;
        it.pszText = "YYY";
        SendMessageA(lv, (UINT)m, 0, (LPARAM)&it);
        memset(buf, 0, sizeof(buf));
        memset(&it, 0, sizeof(it));
        it.mask = 0x0001;
        it.iItem = 0;
        it.iSubItem = 1;
        it.pszText = buf;
        it.cchTextMax = sizeof(buf);
        SendMessageA(lv, LVM_GETITEMTEXTA, 0, (LPARAM)&it);
        n = header_cols(lv);
        if (strcmp(buf, "YYY") == 0) {
            printf("  SETITEMTEXTA candidate: 0x%X (+%d) -> subitem1=\"%s\"\n",
                   m, m - LVM_FIRST, buf);
            if (foundSetText < 0) foundSetText = m;
        }
        DestroyWindow(lv);
    }
    if (foundSetText < 0) printf("  NOT FOUND\n");

    /* 3) 验证 SETITEMSTATE（勾选）@0x102B 与 GETITEMSTATE @0x102C */
    printf("== state image check ==\n");
    {
        HWND lv = make_listview(parent);
        LVCOLUMN_T lc;
        LVITEM_T it;
        LRESULT st;
        memset(&lc, 0, sizeof(lc));
        lc.mask = 0x0001 | 0x0002 | 0x0008;
        lc.cx = 100;
        lc.pszText = "H";
        lc.iSubItem = 0;
        SendMessageA(lv, (UINT)foundInsertCol, 0, (LPARAM)&lc);
        memset(&it, 0, sizeof(it));
        it.mask = 0x0001;
        it.iItem = 0;
        it.iSubItem = 0;
        it.pszText = "ROW0";
        SendMessageA(lv, 0x1007, 0, (LPARAM)&it);
        memset(&it, 0, sizeof(it));
        it.mask = 0x0008; /* LVIF_STATE */
        it.stateMask = LVIS_STATEIMAGEMASK;
        it.state = INDEXTOSTATEIMAGEMASK(2);
        SendMessageA(lv, 0x102B, 0, (LPARAM)&it);   /* LVM_SETITEMSTATE */
        st = SendMessageA(lv, 0x102C, 0, (LPARAM)LVIS_STATEIMAGEMASK); /* GETITEMSTATE */
        printf("  SETITEMSTATE@0x102B then GETITEMSTATE@0x102C = 0x%lX (0x2000=checked)\n",
               (unsigned long)st);
        DestroyWindow(lv);
    }

    DestroyWindow(parent);
    printf("== done ==\n");
    return 0;
}
