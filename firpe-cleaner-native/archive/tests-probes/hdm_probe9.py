# hdm_probe9.py - W 版本列操作：LVM_INSERTCOLUMNW/GETCOLUMNW 验证列头文字
import ctypes
from ctypes import wintypes

u32 = ctypes.WinDLL('user32', use_last_error=True)
comctl = ctypes.WinDLL('comctl32', use_last_error=True)

class ICCEX(ctypes.Structure):
    _fields_ = [('dwSize', wintypes.DWORD), ('dwICC', wintypes.DWORD)]

class LVCOLUMNW(ctypes.Structure):
    _fields_ = [('mask', wintypes.UINT), ('fmt', ctypes.c_int), ('cx', ctypes.c_int),
                ('pszText', ctypes.c_wchar_p), ('cchTextMax', ctypes.c_int),
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

# LVM_INSERTCOLUMNW = 0x1062
lcw = LVCOLUMNW()
lcw.mask = 0x0001 | 0x0002 | 0x0008
lcw.fmt = 0
lcw.cx = 100
lcw.pszText = 'Disk'
lcw.iSubItem = 0
r = u32.SendMessageW(lv, 0x1062, 0, ctypes.byref(lcw))
print('INSERTCOLUMNW ret=%d' % r)
lcw2 = LVCOLUMNW()
lcw2.mask = 0x0001 | 0x0002 | 0x0008
lcw2.fmt = 0
lcw2.cx = 200
lcw2.pszText = 'Model'
lcw2.iSubItem = 1
u32.SendMessageW(lv, 0x1062, 1, ctypes.byref(lcw2))

# LVM_GETCOLUMNW = 0x1060
print('-- LVM_GETCOLUMNW@0x1060 --')
for i in range(2):
    buf = ctypes.create_unicode_buffer(128)
    gc = LVCOLUMNW()
    gc.mask = 0x0001
    gc.pszText = buf
    gc.cchTextMax = 128
    r = u32.SendMessageW(lv, 0x1060, i, ctypes.byref(gc))
    print('  col %d ret=%d text=%r' % (i, r, buf.value))

# HDM_GETITEMW@0x120B
print('-- HDM_GETITEMW@0x120B --')
hdr = u32.SendMessageW(lv, 0x101F, 0, 0)
class HDITW(ctypes.Structure):
    _fields_ = [('mask', wintypes.UINT), ('cxy', ctypes.c_int), ('pszText', ctypes.c_void_p),
                ('hbm', ctypes.c_void_p), ('cchTextMax', ctypes.c_int), ('fmt', ctypes.c_int),
                ('lParam', ctypes.c_longlong), ('iImage', ctypes.c_int), ('iOrder', ctypes.c_int),
                ('type', wintypes.UINT), ('pvFilter', ctypes.c_void_p), ('state', wintypes.UINT)]
for i in range(2):
    buf = ctypes.create_unicode_buffer(128)
    hd = HDITW()
    hd.mask = 0x0002
    hd.pszText = ctypes.cast(buf, ctypes.c_void_p)
    hd.cchTextMax = 128
    r = u32.SendMessageW(hdr, 0x120B, i, ctypes.byref(hd))
    print('  col %d ret=%d text=%r' % (i, r, buf.value))

u32.DestroyWindow(lv)
print('done')
