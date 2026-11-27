# hdm_probe3.py - 决定性实验：定位 HDM_SETTEXTCOLOR/HDM_GETTEXTCOLOR/HDM_SETBKCOLOR/HDM_GETBKCOLOR
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
hdr = u32.SendMessageW(lv, 0x101F, 0, 0)
print('lv=%x hdr=%x' % (lv, hdr))

def rd(m):
    return u32.SendMessageW(hdr, m, 0, 0) & 0xFFFFFFFF

# 1) 用 0x1208 SET 红，然后读各候选号，找返回 0xFF 的（那是 GETTEXTCOLOR）
u32.SendMessageW(hdr, 0x1208, 0, 0x0000FF)
print('-- 0x1208 设红后，读候选（返回 FF0000 的是 GETTEXTCOLOR）--')
for m in [0x1209, 0x120B, 0x120C, 0x120D, 0x120E, 0x120F]:
    print('  read@0x%04X -> 0x%lX' % (m, rd(m)))
print('  read@0x1208(最后读,有副作用) -> 0x%lX' % rd(0x1208))

# 2) 背景色：0x120A 无参读当前（-1 默认）。用候选 SETBK 设绿，读 0x120A 找变化的
print('\n-- 背景色 SETBK 候选（设绿 0x00FF00），读 0x120A --')
for m in [0x1209, 0x120C, 0x120D, 0x120E, 0x1208]:
    try:
        u32.SendMessageW(hdr, m, 0, 0x00FF00)
        v = rd(0x120A)
        print('  SET@0x%04X -> getbk@0x120A = 0x%lX' % (m, v))
        if v == 0x00FF00:
            print('    <== 命中 SETBKCOLOR = 0x%04X' % m)
    except Exception as e:
        print('  SET@0x%04X EXC %s' % (m, e))

# 3) GETBKCOLOR 定位：先 SETBK 绿（已知的命中消息），再读候选号找返回绿值的
print('\n-- 找 GETBKCOLOR（读候选，返回 00FF00 的是）--')
for m in [0x1208, 0x1209, 0x120A, 0x120C, 0x120D, 0x120E]:
    try:
        v = rd(m)
        if v == 0x00FF00:
            print('  read@0x%04X -> 0x%lX  <== GETBKCOLOR = 0x%04X' % (m, v, m))
        else:
            print('  read@0x%04X -> 0x%lX' % (m, v))
    except Exception:
        pass

u32.DestroyWindow(lv)
print('\ndone')
