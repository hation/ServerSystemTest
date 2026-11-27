# hdm_probe4.py - 全区间扫描 SETBKCOLOR：0x1208..0x1215 传绿，读 0x120A 与 0x1208 找变化
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
hdr = u32.SendMessageW(lv, 0x101F, 0, 0)

def rd(m):
    return u32.SendMessageW(hdr, m, 0, 0) & 0xFFFFFFFF

print('-- 无参读 0x1208..0x1218 --')
for m in range(0x1208, 0x1219):
    try:
        print('  0x%04X -> 0x%lX' % (m, rd(m)))
    except Exception as e:
        print('  0x%04X EXC' % m)

print('\n-- 每候选传绿 0x00FF00，读 0x120A(getbk?) 与 0x1209(gettext?) --')
for m in range(0x1208, 0x1216):
    try:
        u32.SendMessageW(hdr, m, 0, 0x00FF00)
        a = rd(0x120A)
        t = rd(0x1209)
        if a == 0x00FF00:
            print('  SET@0x%04X -> getbk@0x120A=0x%lX <== SETBKCOLOR=0x%04X' % (m, a, m))
        elif t == 0x00FF00:
            print('  SET@0x%04X -> gettext@0x1209=0x%lX (SETTEXTCOLOR 候选)' % (m, t))
        else:
            print('  SET@0x%04X -> getbk=0x%lX gettext=0x%lX' % (m, a, t))
    except Exception:
        print('  SET@0x%04X EXC(需指针)' % m)

u32.DestroyWindow(lv)
print('\ndone')
