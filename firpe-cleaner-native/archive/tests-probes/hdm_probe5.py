# hdm_probe5.py - 用 SendMessageA 重测 HDM 颜色消息（A/W 区分）
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
# A 版本创建
lv = u32.CreateWindowExA(0, b'SysListView32', b'', 0x40000000 | 0x10000000 | 1, 0, 0, 300, 200, u32.GetDesktopWindow(), None, None, None)
lc = LVCOLUMNA(0x0001 | 0x0002 | 0x0008, 0, 100, b'Disk', 0, 0, 0, 0)
u32.SendMessageA(lv, 0x1061, 0, ctypes.byref(lc))
hdr = u32.SendMessageA(lv, 0x101F, 0, 0)
print('lv=%x hdr=%x cols=%d' % (lv, hdr, u32.SendMessageA(hdr, 0x1200, 0, 0)))

def rd(m):
    return u32.SendMessageA(hdr, m, 0, 0) & 0xFFFFFFFF

# 1) 0x1208 传红
u32.SendMessageA(hdr, 0x1208, 0, 0x0000FF)
print('after 0x1208=red: read 0x1208=0x%lX  0x1209=0x%lX' % (rd(0x1208), rd(0x1209)))

# 2) 0x1209 传蓝
u32.SendMessageA(hdr, 0x1209, 0, 0x0000FF00 & 0xFFFFFFFF)  # 蓝 0xFF0000? 用 0x0000FF 变体
print('after 0x1209=set: read 0x1208=0x%lX  0x1209=0x%lX' % (rd(0x1208), rd(0x1209)))

# 3) 背景：0x120A 传绿（COLORREF），捕获崩溃
print('-- 0x120A / 0x120B 传 COLORREF(绿) --')
for m in (0x120A, 0x120B):
    try:
        u32.SendMessageA(hdr, m, 0, 0x00FF00)
        print('  SET@0x%04X ok, getbk@0x120A=0x%lX' % (m, rd(0x120A)))
    except Exception as e:
        print('  SET@0x%04X EXC %s' % (m, e))

# 4) 全候选 SETBK（绿），读 0x120A
print('-- SETBK 扫描(传绿)，读 0x120A --')
for m in range(0x1208, 0x1216):
    try:
        u32.SendMessageA(hdr, m, 0, 0x00FF00)
        a = rd(0x120A)
        if a == 0x00FF00:
            print('  SET@0x%04X -> getbk=0x%lX <== SETBKCOLOR=0x%04X' % (m, a, m))
    except Exception:
        print('  SET@0x%04X EXC' % m)

# 5) GETITEMA 文本读（A 消息 + A 结构）
print('-- HDM_GETITEMA@0x1203 (SendMessageA) --')
class HDITA(ctypes.Structure):
    _fields_ = [('mask', wintypes.UINT), ('cxy', ctypes.c_int), ('pszText', ctypes.c_void_p),
                ('hbm', ctypes.c_void_p), ('cchTextMax', ctypes.c_int), ('fmt', ctypes.c_int),
                ('lParam', ctypes.c_longlong), ('iImage', ctypes.c_int), ('iOrder', ctypes.c_int),
                ('type', wintypes.UINT), ('pvFilter', ctypes.c_void_p), ('state', wintypes.UINT)]
buf = ctypes.create_string_buffer(256)
hd = HDITA()
hd.mask = 0x0002
hd.pszText = ctypes.cast(buf, ctypes.c_void_p)
hd.cchTextMax = 256
r = u32.SendMessageA(hdr, 0x1203, 0, ctypes.byref(hd))
print('  ret=%d text=%r mask=0x%X' % (r, buf.value, hd.mask))

u32.DestroyWindow(lv)
print('\ndone')
