# hdm_probe2.py - 全区间扫描：找能改变 GETTEXTCOLOR(0x1208)/GETBKCOLOR(0x120A) 的 SET 消息
import ctypes, sys
from ctypes import wintypes

u32 = ctypes.WinDLL('user32', use_last_error=True)
comctl = ctypes.WinDLL('comctl32', use_last_error=True)

class ICCEX(ctypes.Structure):
    _fields_ = [('dwSize', wintypes.DWORD), ('dwICC', wintypes.DWORD)]

class LVCOLUMNA(ctypes.Structure):
    _fields_ = [('mask', wintypes.UINT), ('fmt', ctypes.c_int), ('cx', ctypes.c_int),
                ('pszText', ctypes.c_char_p), ('cchTextMax', ctypes.c_int),
                ('iSubItem', ctypes.c_int), ('iImage', ctypes.c_int), ('iOrder', ctypes.c_int)]

u32.CreateWindowExW.restype = wintypes.HWND
u32.CreateWindowExW.argtypes = [wintypes.DWORD, wintypes.LPCWSTR, wintypes.LPCWSTR,
                                wintypes.DWORD, ctypes.c_int, ctypes.c_int, ctypes.c_int,
                                ctypes.c_int, wintypes.HWND, wintypes.HMENU,
                                wintypes.HINSTANCE, wintypes.LPVOID]
u32.SendMessageW.restype = ctypes.c_longlong
u32.SendMessageW.argtypes = [wintypes.HWND, wintypes.UINT, ctypes.c_void_p, ctypes.c_void_p]
u32.GetDesktopWindow.restype = wintypes.HWND
u32.DestroyWindow.restype = wintypes.BOOL
u32.DestroyWindow.argtypes = [wintypes.HWND]

icc = ICCEX(ctypes.sizeof(ICCEX), 1)
comctl.InitCommonControlsEx(ctypes.byref(icc))
lv = u32.CreateWindowExW(0, 'SysListView32', '', 0x40000000 | 0x10000000 | 1, 0, 0, 300, 200, u32.GetDesktopWindow(), None, None, None)
lc = LVCOLUMNA(0x0001 | 0x0002 | 0x0008, 0, 100, b'Disk', 0, 0, 0, 0)
u32.SendMessageW(lv, 0x1061, 0, ctypes.byref(lc))
hdr = u32.SendMessageW(lv, 0x101F, 0, 0)
print('lv=%x hdr=%x cols=%d' % (lv, hdr, u32.SendMessageW(hdr, 0x1200, 0, 0)))

# 扫 0x1200..0x1220：传红色 COLORREF，观察 gettext(0x1208)/getbk(0x120A) 变化
print('\n-- 扫描 SET 消息（传红 0x0000FF），看 0x1208/0x120A 是否改变 --')
for m in range(0x1200, 0x1221):
    try:
        u32.SendMessageW(hdr, m, 0, 0x0000FF)
        g8 = u32.SendMessageW(hdr, 0x1208, 0, 0) & 0xFFFFFFFF
        gA = u32.SendMessageW(hdr, 0x120A, 0, 0) & 0xFFFFFFFF
        if g8 != 0 or gA != 0xFFFFFFFF:
            print('  0x%04X: gettext=0x%lX getbk=0x%lX  <== 有变化!' % (m, g8, gA))
    except Exception:
        pass  # 崩溃的消息忽略（需指针）
print('  扫描完成（0x1208 基准=0，0x120A 基准=FFFFFFFF）')

# 恢复默认，再对 LVM 层测颜色：LVM_GETTEXTCOLOR=0x1023, LVM_SETTEXTCOLOR=0x1024, LVM_GETBKCOLOR=0x1000, LVM_SETBKCOLOR=0x1001
print('\n-- LVM 颜色消息 --')
print('  LVM_GETBKCOLOR@0x1000 = 0x%lX' % (u32.SendMessageW(lv, 0x1000, 0, 0) & 0xFFFFFFFF))
print('  LVM_GETTEXTCOLOR@0x1023 = 0x%lX' % (u32.SendMessageW(lv, 0x1023, 0, 0) & 0xFFFFFFFF))
u32.SendMessageW(lv, 0x1024, 0, 0x0000FF)   # LVM_SETTEXTCOLOR 候选
print('  after SET@0x1024: GETTEXTCOLOR@0x1023 = 0x%lX (期望 FF0000)' % (u32.SendMessageW(lv, 0x1023, 0, 0) & 0xFFFFFFFF))
u32.SendMessageW(lv, 0x1001, 0, 0x00FF00)   # LVM_SETBKCOLOR 候选
print('  after SET@0x1001: GETBKCOLOR@0x1000 = 0x%lX (期望 00FF00)' % (u32.SendMessageW(lv, 0x1000, 0, 0) & 0xFFFFFFFF))

# header 层的 SET 消息全试（传 COLORREF 不崩溃的），看 0x1208/0x120A 读值
print('\n-- 对 hdr 依次 SET 颜色候选（红），看 gettext@0x1208 --')
u32.SendMessageW(hdr, 0x1209, 0, 0x0000FF)
print('  after SET@0x1209: gettext@0x1208 = 0x%lX' % (u32.SendMessageW(hdr, 0x1208, 0, 0) & 0xFFFFFFFF))
u32.SendMessageW(hdr, 0x120C, 0, 0x0000FF)
print('  after SET@0x120C: gettext@0x1208 = 0x%lX' % (u32.SendMessageW(hdr, 0x1208, 0, 0) & 0xFFFFFFFF))
u32.SendMessageW(hdr, 0x120D, 0, 0x0000FF)
print('  after SET@0x120D: gettext@0x1208 = 0x%lX' % (u32.SendMessageW(hdr, 0x1208, 0, 0) & 0xFFFFFFFF))

u32.DestroyWindow(lv)
print('\ndone')
