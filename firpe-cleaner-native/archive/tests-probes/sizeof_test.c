/* sizeof/offsetof 验证：LVITEMA / LVCOLUMNA 与 SDK 权威值对照（x86/x64） */
#include <stdio.h>
#include <stddef.h>
#include <windows.h>
#include "../src/patches.h"

int main(void)
{
    printf("ptr=%zu int=%zu UINT=%zu LPARAM=%zu LONG_PTR=%zu\n",
           sizeof(void*), sizeof(int), sizeof(UINT), sizeof(LPARAM), sizeof(LONG_PTR));
    printf("sizeof(LVITEMA)=%zu\n", sizeof(LVITEMA));
    printf("  offsetof(mask)=%zu iItem=%zu iSubItem=%zu state=%zu stateMask=%zu\n",
           offsetof(LVITEMA, mask), offsetof(LVITEMA, iItem), offsetof(LVITEMA, iSubItem),
           offsetof(LVITEMA, state), offsetof(LVITEMA, stateMask));
    printf("  offsetof(pszText)=%zu cchTextMax=%zu iImage=%zu lParam=%zu\n",
           offsetof(LVITEMA, pszText), offsetof(LVITEMA, cchTextMax),
           offsetof(LVITEMA, iImage), offsetof(LVITEMA, lParam));
    printf("  offsetof(iIndent)=%zu iGroupId=%zu cColumns=%zu puColumns=%zu piColFmt=%zu iGroup=%zu\n",
           offsetof(LVITEMA, iIndent), offsetof(LVITEMA, iGroupId), offsetof(LVITEMA, cColumns),
           offsetof(LVITEMA, puColumns), offsetof(LVITEMA, piColFmt), offsetof(LVITEMA, iGroup));
    printf("sizeof(LVCOLUMNA)=%zu\n", sizeof(LVCOLUMNA));
    printf("  offsetof(mask)=%zu fmt=%zu cx=%zu pszText=%zu cchTextMax=%zu iSubItem=%zu iImage=%zu iOrder=%zu\n",
           offsetof(LVCOLUMNA, mask), offsetof(LVCOLUMNA, fmt), offsetof(LVCOLUMNA, cx),
           offsetof(LVCOLUMNA, pszText), offsetof(LVCOLUMNA, cchTextMax),
           offsetof(LVCOLUMNA, iSubItem), offsetof(LVCOLUMNA, iImage), offsetof(LVCOLUMNA, iOrder));
    printf("LVM_INSERTCOLUMNA=%d LVM_INSERTITEMA=%d LVM_GETITEMCOUNT=%d LVM_DELETEALLITEMS=%d\n",
           LVM_INSERTCOLUMNA, LVM_INSERTITEMA, LVM_GETITEMCOUNT, LVM_DELETEALLITEMS);
    printf("LVM_SETEXTENDEDLISTVIEWSTYLE=%d LVM_GETITEMSTATE=%d LVM_SETITEMSTATE=%d\n",
           LVM_SETEXTENDEDLISTVIEWSTYLE, LVM_GETITEMSTATE, LVM_SETITEMSTATE);
    printf("LVM_SETITEMTEXTA=%d (SDK 权威值应=0x102E/46; 45=GETITEMTEXTA)\n", LVM_SETITEMTEXTA);
    return 0;
}
