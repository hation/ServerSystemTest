# hdm_probe.py - 用 ctypes 直接探测 SysHeader32 的 HDM 消息真实值
# 目标：确定 HDM_SETTEXTCOLOR / HDM_SETBKCOLOR / HDM_GETITEMA 的行为
import ctypes, sys
from ctypes import wintypes

u32 = ctypes.WinDLL('user32', use_last_error=True)
comctl = ctypes.WinDLL('comctl32', use_last_error=True)

# INITCOMMONCONTROLSEX
class ICCEX(ctypes.Structure):
    _fields_ = [('dwSize', wintypes.DWORD), ('dwICC', wintypes.DWORD)]

icc = ICCEX(ctypes.sizeof(ICCEX), 1)
r = comctl.InitCommonControlsEx(ctypes.byref(icc))
print('InitCommonControlsEx =', r)

# LVCOLUMNA
class LVCOLUMNA(ctypes.Structure):
    _fields_ = [('mask', wintypes.UINT), ('fmt', ctypes.c_int), ('cx', ctypes.c_int),
                ('pszText', ctypes.c_char_p), ('cchTextMax', ctypes.c_int),
                ('iSubItem', ctypes.c_int), ('iImage', ctypes.c_int), ('iOrder', ctypes.c_int)]

# HDITEM（完整版）
class HDITEM(ctypes.Structure):
    _fields_ = [('mask', wintypes.UINT), ('cxy', ctypes.c_int), ('pszText', ctypes.c_void_p),
                ('hbm', ctypes.c_void_p), ('cchTextMax', ctypes.c_int), ('fmt', ctypes.c_int),
                ('lParam', ctypes.c_longlong), ('iImage', ctypes.c_int), ('iOrder', ctypes.c_int),
                ('type', wintypes.UINT), ('pvFilter', ctypes.c_void_p), ('state', wintypes.UINT)]

# 创建 ListView（父窗口=桌面）
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

hparent = u32.GetDesktopWindow()
cls = 'SysListView32'
lv = u32.CreateWindowExW(0, cls, '', 0x40000000 | 0x10000000 | 1, 0, 0, 300, 200, hparent, None, None, None)
if not lv:
    print('CreateWindowExW failed err=', ctypes.get_last_error()); sys.exit(1)
print('lv =', hex(lv))

LVM_INSERTCOLUMNA = 0x1061
LVM_GETHEADER = 0x101F
HDM_GETITEMCOUNT = 0x1200

lc = LVCOLUMNA(0x0001 | 0x0002 | 0x0008, 0, 100, b'Disk', 0, 0, 0, 0)
u32.SendMessageW(lv, LVM_INSERTCOLUMNA, 0, ctypes.byref(lc))
hdr = u32.SendMessageW(lv, LVM_GETHEADER, 0, 0)
print('hdr =', hex(hdr))
print('cols =', u32.SendMessageW(hdr, HDM_GETITEMCOUNT, 0, 0))

# ---- 候选消息扫描：无参读（wParam=0, lParam=0），不崩溃的可能是 GET 类 ----
print('\n-- 无参读 0x1200..0x120F --')
for m in range(0x1200, 0x1210):
    try:
        v = u32.SendMessageW(hdr, m, 0, 0)
        print('  0x%04X -> 0x%lX' % (m, v))
    except Exception as e:
        print('  0x%04X -> EXC %s' % (m, e))

# ---- 颜色 SET 候选：对 0x1209..0x120E 传 COLORREF，看哪个不崩溃且改变 GET 值 ----
print('\n-- SET 候选传 COLORREF(红) --')
for m in range(0x1209, 0x120E):
    try:
        v = u32.SendMessageW(hdr, m, 0, 0x0000FF)
        g8 = u32.SendMessageW(hdr, 0x1208, 0, 0)
        gA = u32.SendMessageW(hdr, 0x120A, 0, 0)
        print('  SET@0x%04X ret=0x%lX -> gettext@0x1208=0x%lX getbk@0x120A=0x%lX' % (m, v, g8, gA))
    except Exception as e:
        print('  SET@0x%04X -> EXC %s' % (m, e))

# ---- HDM_GETITEMA 文本读 ----
print('\n-- HDM_GETITEMA@0x1203 --')
buf = ctypes.create_string_buffer(256)
hd = HDITEM()
hd.mask = 0x0002  # HDI_TEXT
hd.pszText = ctypes.cast(buf, ctypes.c_void_p)
hd.cchTextMax = 256
r = u32.SendMessageW(hdr, 0x1203, 0, ctypes.byref(hd))
print('  GETITEMA ret=%d text=%r' % (r, buf.value))

# HDM_GETITEMW = 0x120B（候选）
print('\n-- HDM_GETITEMW@0x120B --')
buf2 = ctypes.create_string_buffer(512)
hdw = HDITEM()
hdw.mask = 0x0002
hdw.pszText = ctypes.cast(buf2, ctypes.c_void_p)
hdw.cchTextMax = 256
r = u32.SendMessageW(hdr, 0x120B, 0, ctypes.byref(hdw))
print('  GETITEMW ret=%d raw=%r' % (r, buf2.raw[:64]))

# HDM_GETITEMW = 0x1209（候选）
print('\n-- 0x1209 带 HDITEM 指针 --')
buf3 = ctypes.create_string_buffer(512)
hd9 = HDITEM()
hd9.mask = 0x0002
hd9.pszText = ctypes.cast(buf3, ctypes.c_void_p)
hd9.cchTextMax = 256
r = u32.SendMessageW(hdr, 0x1209, 0, ctypes.byref(hd9))
print('  0x1209 ret=%d raw=%r' % (r, buf3.raw[:64]))

u32.DestroyWindow(lv)
print('\ndone')
