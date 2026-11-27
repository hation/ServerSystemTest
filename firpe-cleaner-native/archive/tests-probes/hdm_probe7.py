# hdm_probe7.py - 补扫 0x1204/0x1205/0x1217-0x1222 找 SETBKCOLOR
import ctypes
from ctypes import wintypes

u32 = ctypes.WinDLL('user32', use_last_error=True)
comctl = ctypes.WinDLL('comctl32', use_last_error=True)

class ICCEX(ctypes.Structure):
    _fields_ = [('dwSize', wintypes.DWORD), ('dwICC', wintypes.DWORD)]

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

def rd(m):
    return u32.SendMessageA(hdr, m, 0, 0) & 0xFFFFFFFF

print('-- 补扫 SETBKCOLOR（传绿 0x00FF00，读 0x120A）--')
for m in [0x1204, 0x1205, 0x1217, 0x1218, 0x1219, 0x121A, 0x121B, 0x121C, 0x121D, 0x121E, 0x121F, 0x1220]:
    try:
        u32.SendMessageA(hdr, m, 0, 0x00FF00)
        a = rd(0x120A)
        if a == 0x00FF00:
            print('  SET@0x%04X -> getbk=0x%lX <== SETBKCOLOR=0x%04X' % (m, a, m))
        else:
            print('  SET@0x%04X -> getbk=0x%lX' % (m, a))
    except Exception:
        print('  SET@0x%04X EXC' % m)

u32.DestroyWindow(lv)
print('done')
