# hdm_probe6.py - 最后确认：0x120A 语义 + header 背景跟随性
import ctypes
from ctypes import wintypes

u32 = ctypes.WinDLL('user32', use_last_error=True)
comctl = ctypes.WinDLL('comctl32', use_last_error=True)

class ICCEX(ctypes.Structure):
    _fields_ = [('dwSize', wintypes.DWORD), ('dwICC', wintypes.DWORD)]

class LVCOLUMNA(ctypes.Structure):
    _fields_ = [('mask', wintypes.UINT), ('fmt', ctypes.c_int), ('cx', ctypes.c_int),
                ('pszText', ctypes.c_char_p), ('cchTextMax', ctypes.c_int),
                ('iSubItem', ctypes.c_int), ('iImage', ctypes.c_int), ('iOrder', ctypes.c_int)]

u32.CreateWindowExA.restype = wintypes.HWND
u32.CreateWindowExA.argtypes = [wintypes.DWORD, ctypes.c_char_p, ctypes.c_char_p,
                                wintypes.DWORD, ctypes.c_int, ctypes.c_int, ctypes.c_int,
                                ctypes.c_int, wintypes.HWND, wintypes.HMENU,
                                wintypes.HINSTANCE, wintypes.LPVOID]
u32.SendMessageA.restype = ctypes.c_longlong
u32.SendMessageA.argtypes = [wintypes.HWND, wintypes.UINT, ctypes.c_void_p, ctypes.c_void_p]
u32.GetDesktopWindow.restype = wintypes.HWND
u32.DestroyWindow.restype = wintypes.BOOL
u32.DestroyWindow.argtypes = [wintypes.HWND]

icc = ICCEX(ctypes.sizeof(ICCEX), 1)
comctl.InitCommonControlsEx(ctypes.byref(icc))
lv = u32.CreateWindowExA(0, b'SysListView32', b'', 0x40000000 | 0x10000000 | 1, 0, 0, 300, 200, u32.GetDesktopWindow(), None, None, None)
hdr = u32.SendMessageA(lv, 0x101F, 0, 0)

def rd(m, l=0):
    return u32.SendMessageA(hdr, m, 0, l) & 0xFFFFFFFF

# 1) 0x1207 传 RECT 指针（GETITEMRECT 候选）
class RECT(ctypes.Structure):
    _fields_ = [('l', ctypes.c_long), ('t', ctypes.c_long), ('r', ctypes.c_long), ('b', ctypes.c_long)]
rc = RECT(0, 0, 0, 0)
r = u32.SendMessageA(hdr, 0x1207, 0, ctypes.byref(rc))
print('0x1207 GETITEMRECT? ret=%d rect=(%d,%d,%d,%d)' % (r, rc.l, rc.t, rc.r, rc.b))

# 2) 0x120A 传 HDITEM 指针（判断是否需指针消息）
class HDITA(ctypes.Structure):
    _fields_ = [('mask', wintypes.UINT), ('cxy', ctypes.c_int), ('pszText', ctypes.c_void_p),
                ('hbm', ctypes.c_void_p), ('cchTextMax', ctypes.c_int), ('fmt', ctypes.c_int),
                ('lParam', ctypes.c_longlong), ('iImage', ctypes.c_int), ('iOrder', ctypes.c_int),
                ('type', wintypes.UINT), ('pvFilter', ctypes.c_void_p), ('state', wintypes.UINT)]
buf = ctypes.create_string_buffer(128)
hd = HDITA()
hd.mask = 0xFFFF
hd.pszText = ctypes.cast(buf, ctypes.c_void_p)
hd.cchTextMax = 128
r = u32.SendMessageA(hdr, 0x120A, 0, ctypes.byref(hd))
print('0x120A with HDITEM* ret=%d mask=0x%X fmt=0x%X' % (r, hd.mask, hd.fmt))

# 3) header 背景跟随 ListView 背景？
print('\n-- header 背景 vs ListView 背景 --')
print('  before: hdr-bk@0x120A=0x%lX, lv-bk@0x1000=0x%lX' % (rd(0x120A), u32.SendMessageA(lv, 0x1000, 0, 0) & 0xFFFFFFFF))
u32.SendMessageA(lv, 0x1001, 0, 0x00FF00)   # LVM_SETBKCOLOR 绿
print('  after LVM_SETBKCOLOR(green): hdr-bk@0x120A=0x%lX, lv-bk@0x1000=0x%lX' % (rd(0x120A), u32.SendMessageA(lv, 0x1000, 0, 0) & 0xFFFFFFFF))

# 4) LVM_SETTEXTCOLOR=0x1024 对 header 文本色的影响？
print('-- LVM_SETTEXTCOLOR 影响 header? --')
u32.SendMessageA(lv, 0x1024, 0, 0x0000FF)   # LVM_SETTEXTCOLOR 红
print('  after LVM_SETTEXTCOLOR(red): hdr-text@0x1209=0x%lX, lv-text@0x1023=0x%lX' % (rd(0x1209), u32.SendMessageA(lv, 0x1023, 0, 0) & 0xFFFFFFFF))

u32.DestroyWindow(lv)
print('\ndone')
