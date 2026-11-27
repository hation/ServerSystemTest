# hdm_probe8.py - LVM_GETCOLUMNA 验证列头文字存储
import ctypes
from ctypes import wintypes

u32 = ctypes.WinDLL('user32', use_last_error=True)
comctl = ctypes.WinDLL('comctl32', use_last_error=True)

class ICCEX(ctypes.Structure):
    _fields_ = [('dwSize', wintypes.DWORD), ('dwICC', wintypes.DWORD)]

class LVCOLUMNA(ctypes.Structure):
    _fields_ = [('mask', wintypes.UINT), ('fmt', ctypes.c_int), ('cx', ctypes.c_int),
                ('pszText', ctypes.c_void_p), ('cchTextMax', ctypes.c_int),
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

# 插入两列（用 0x1061 = LVM_INSERTCOLUMNA）
lc1 = LVCOLUMNA()
lc1.mask = 0x0001 | 0x0002 | 0x0008
lc1.fmt = 0
lc1.cx = 100
lc1.pszText = ctypes.cast(ctypes.create_string_buffer(b'Disk', 8), ctypes.c_void_p)
lc1.iSubItem = 0
u32.SendMessageA(lv, 0x1061, 0, ctypes.byref(lc1))
lc2 = LVCOLUMNA()
lc2.mask = 0x0001 | 0x0002 | 0x0008
lc2.fmt = 0
lc2.cx = 200
lc2.pszText = ctypes.cast(ctypes.create_string_buffer(b'Model', 8), ctypes.c_void_p)
lc2.iSubItem = 1
u32.SendMessageA(lv, 0x1061, 1, ctypes.byref(lc2))

# LVM_GETCOLUMNA = 0x105F，读回列定义
print('-- LVM_GETCOLUMNA@0x105F --')
for i in range(2):
    buf = ctypes.create_string_buffer(128)
    gc = LVCOLUMNA()
    gc.mask = 0x0001  # LVCF_TEXT
    gc.pszText = ctypes.cast(buf, ctypes.c_void_p)
    gc.cchTextMax = 128
    r = u32.SendMessageA(lv, 0x105F, i, ctypes.byref(gc))
    print('  col %d ret=%d text=%r' % (i, r, buf.value))

# 再试 HDM_GETITEMA（对照）
hdr = u32.SendMessageA(lv, 0x101F, 0, 0)
class HDITA(ctypes.Structure):
    _fields_ = [('mask', wintypes.UINT), ('cxy', ctypes.c_int), ('pszText', ctypes.c_void_p),
                ('hbm', ctypes.c_void_p), ('cchTextMax', ctypes.c_int), ('fmt', ctypes.c_int),
                ('lParam', ctypes.c_longlong), ('iImage', ctypes.c_int), ('iOrder', ctypes.c_int),
                ('type', wintypes.UINT), ('pvFilter', ctypes.c_void_p), ('state', wintypes.UINT)]
print('-- HDM_GETITEMA@0x1203 对照 --')
for i in range(2):
    buf = ctypes.create_string_buffer(128)
    hd = HDITA()
    hd.mask = 0x0002
    hd.pszText = ctypes.cast(buf, ctypes.c_void_p)
    hd.cchTextMax = 128
    r = u32.SendMessageA(hdr, 0x1203, i, ctypes.byref(hd))
    print('  col %d ret=%d text=%r' % (i, r, buf.value))

u32.DestroyWindow(lv)
print('done')
