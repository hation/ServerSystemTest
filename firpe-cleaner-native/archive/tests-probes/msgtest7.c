/* msgtest7.c - HDM_GETITEMA 列头文字 + HDM 颜色消息权威值验证（v2） */
#include <windows.h>
#include <stdio.h>
#include <string.h>

typedef struct { DWORD dwSize; DWORD dwICC; } ICCEX;
extern BOOL WINAPI InitCommonControlsEx(const ICCEX* picc);

typedef struct { UINT mask; int fmt; int cx; LPCSTR pszText; int cchTextMax; int iSubItem; int iImage; int iOrder; } LVCOLUMN_T;
typedef struct { UINT mask; int cxy; LPCSTR pszText; HANDLE hbm; int cchTextMax; int fmt; LPARAM lParam; int iImage; int iOrder; } HDITEM9;
typedef struct { UINT mask; int cxy; LPCSTR pszText; HANDLE hbm; int cchTextMax; int fmt; LPARAM lParam; int iImage; int iOrder; UINT type; void* pvFilter; UINT state; } HDITEMFULL;

int main(void)
{
    setvbuf(stderr, NULL, _IONBF, 0);
    ICCEX icc; icc.dwSize = sizeof(icc); icc.dwICC = 1;
    InitCommonControlsEx(&icc);
    fprintf(stderr, "init ok\n");
    {
        HWND lv = CreateWindowExA(0, "SysListView32", "", WS_CHILD | WS_VISIBLE | 1,
                                  0, 0, 300, 200, GetDesktopWindow(), NULL, GetModuleHandleA(NULL), NULL);
        LVCOLUMN_T lc; char buf[256];
        HWND hdr; LRESULT r;
        int i;
        if (!lv) { fprintf(stderr, "lv failed err=%lu\n", (unsigned long)GetLastError()); return 1; }
        memset(&lc, 0, sizeof(lc)); lc.mask = 1 | 2 | 8; lc.cx = 100; lc.pszText = "Disk"; lc.iSubItem = 0;
        SendMessageA(lv, 0x1061, 0, (LPARAM)&lc);
        hdr = (HWND)SendMessageA(lv, 0x101F, 0, 0);
        fprintf(stderr, "hdr=%p cols=%d\n", (void*)hdr, hdr ? (int)SendMessageA(hdr, 0x1200, 0, 0) : -1);
        if (!hdr) return 1;

        /* A) HDM_GETITEMA 用 9 字段结构 */
        for (i = 0; i < 1; i++) {
            HDITEM9 hd;
            memset(buf, 0, sizeof(buf));
            memset(&hd, 0, sizeof(hd));
            hd.mask = 2; hd.pszText = buf; hd.cchTextMax = sizeof(buf);
            r = SendMessageA(hdr, 0x1203, (WPARAM)i, (LPARAM)&hd);
            fprintf(stderr, "A) 9-field  col %d ret=%ld mask=0x%X text=\"%s\"\n", i, (long)r, hd.mask, buf);
        }
        /* B) HDM_GETITEMA 用完整 SDK 结构 */
        for (i = 0; i < 1; i++) {
            HDITEMFULL hd;
            memset(buf, 0, sizeof(buf));
            memset(&hd, 0, sizeof(hd));
            hd.mask = 2; hd.pszText = buf; hd.cchTextMax = sizeof(buf);
            r = SendMessageA(hdr, 0x1203, (WPARAM)i, (LPARAM)&hd);
            fprintf(stderr, "B) full     col %d ret=%ld mask=0x%X text=\"%s\"\n", i, (long)r, hd.mask, buf);
        }

        /* C) HDM 颜色 SET 消息甄别：0x1209 崩溃（需指针），试 0x120B
         * GETTEXTCOLOR=0x1208, GETBKCOLOR=0x120A 已确认（无参读） */
        fprintf(stderr, "C) before: gettext@0x1208=0x%lX getbk@0x120A=0x%lX\n",
               (unsigned long)SendMessageA(hdr, 0x1208, 0, 0),
               (unsigned long)SendMessageA(hdr, 0x120A, 0, 0));
        SendMessageA(hdr, 0x120B, 0, (LPARAM)RGB(255, 0, 0));   /* 候选 SETTEXT 或 SETBK */
        fprintf(stderr, "C) after @0x120B red: gettext@0x1208=0x%lX getbk@0x120A=0x%lX\n",
               (unsigned long)SendMessageA(hdr, 0x1208, 0, 0),
               (unsigned long)SendMessageA(hdr, 0x120A, 0, 0));
        SendMessageA(hdr, 0x120B, 0, (LPARAM)RGB(0, 0, 255));   /* 再发蓝确认 */
        fprintf(stderr, "C) after @0x120B blue: gettext@0x1208=0x%lX getbk@0x120A=0x%lX\n",
               (unsigned long)SendMessageA(hdr, 0x1208, 0, 0),
               (unsigned long)SendMessageA(hdr, 0x120A, 0, 0));

        /* D) LVM 颜色：0x1003 GETTEXT / 0x1004 SETTEXT / 0x1000 GETBK / 0x1001 SETBK */
        fprintf(stderr, "D) before: lvtext@0x1003=0x%lX lvbk@0x1000=0x%lX\n",
               (unsigned long)SendMessageA(lv, 0x1003, 0, 0),
               (unsigned long)SendMessageA(lv, 0x1000, 0, 0));
        SendMessageA(lv, 0x1004, 0, (LPARAM)RGB(0, 0, 0));
        SendMessageA(lv, 0x1001, 0, (LPARAM)RGB(255, 255, 255));
        fprintf(stderr, "D) after : lvtext@0x1003=0x%lX lvbk@0x1000=0x%lX (期望 0/FFFFFF)\n",
               (unsigned long)SendMessageA(lv, 0x1003, 0, 0),
               (unsigned long)SendMessageA(lv, 0x1000, 0, 0));

        DestroyWindow(lv);
    }
    fprintf(stderr, "done\n");
    return 0;
}
