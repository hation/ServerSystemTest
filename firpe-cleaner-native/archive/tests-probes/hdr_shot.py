# hdr_shot.py - 创建顶层窗口显示 ListView，截取列头区域验证文字是否可见
import ctypes, time, struct
from ctypes import wintypes

u32 = ctypes.WinDLL('user32', use_last_error=True)
gdi = ctypes.WinDLL('gdi32', use_last_error=True)
comctl = ctypes.WinDLL('comctl32', use_last_error=True)
k32 = ctypes.WinDLL('kernel32', use_last_error=True)

# ---- 类型声明 ----
WNDPROC = ctypes.WINFUNCTYPE(ctypes.c_longlong, wintypes.HWND, wintypes.UINT, wintypes.WPARAM, wintypes.LPARAM)
class WNDCLASSEXA(ctypes.Structure):
    _fields_ = [('cbSize', wintypes.UINT), ('style', wintypes.UINT), ('lpfnWndProc', WNDPROC),
                ('cbClsExtra', ctypes.c_int), ('cbWndExtra', ctypes.c_int),
                ('hInstance', wintypes.HINSTANCE), ('hIcon', wintypes.HANDLE),
                ('hCursor', wintypes.HANDLE), ('hbrBackground', wintypes.HANDLE),
                ('lpszMenuName', ctypes.c_char_p), ('lpszClassName', ctypes.c_char_p),
                ('hIconSm', wintypes.HANDLE)]

class ICCEX(ctypes.Structure):
    _fields_ = [('dwSize', wintypes.DWORD), ('dwICC', wintypes.DWORD)]

class LVCOLUMNA(ctypes.Structure):
    _fields_ = [('mask', wintypes.UINT), ('fmt', ctypes.c_int), ('cx', ctypes.c_int),
                ('pszText', ctypes.c_char_p), ('cchTextMax', ctypes.c_int),
                ('iSubItem', ctypes.c_int), ('iImage', ctypes.c_int), ('iOrder', ctypes.c_int)]

class BITMAPINFOHEADER(ctypes.Structure):
    _fields_ = [('biSize', wintypes.DWORD), ('biWidth', ctypes.c_long), ('biHeight', ctypes.c_long),
                ('biPlanes', wintypes.WORD), ('biBitCount', wintypes.WORD),
                ('biCompression', wintypes.DWORD), ('biSizeImage', wintypes.DWORD),
                ('biXPelsPerMeter', ctypes.c_long), ('biYPelsPerMeter', ctypes.c_long),
                ('biClrUsed', wintypes.DWORD), ('biClrImportant', wintypes.DWORD)]

u32.DefWindowProcA.restype = ctypes.c_longlong
u32.DefWindowProcA.argtypes = [wintypes.HWND, wintypes.UINT, wintypes.WPARAM, wintypes.LPARAM]
u32.CreateWindowExA.restype = wintypes.HWND
u32.CreateWindowExA.argtypes = [wintypes.DWORD, ctypes.c_char_p, ctypes.c_char_p,
                                wintypes.DWORD, ctypes.c_int, ctypes.c_int, ctypes.c_int,
                                ctypes.c_int, wintypes.HWND, wintypes.HMENU,
                                wintypes.HINSTANCE, wintypes.LPVOID]
u32.SendMessageA.restype = ctypes.c_longlong
u32.SendMessageA.argtypes = [wintypes.HWND, wintypes.UINT, ctypes.c_void_p, ctypes.c_void_p]
u32.RegisterClassExA.restype = wintypes.WORD
u32.RegisterClassExA.argtypes = [ctypes.POINTER(WNDCLASSEXA)]
u32.GetDesktopWindow.restype = wintypes.HWND
u32.ShowWindow.restype = wintypes.BOOL
u32.ShowWindow.argtypes = [wintypes.HWND, ctypes.c_int]
u32.UpdateWindow.restype = wintypes.BOOL
u32.UpdateWindow.argtypes = [wintypes.HWND]
u32.GetDC.restype = wintypes.HDC
u32.GetDC.argtypes = [wintypes.HWND]
u32.ReleaseDC.restype = ctypes.c_int
u32.ReleaseDC.argtypes = [wintypes.HWND, wintypes.HDC]
u32.GetClientRect.restype = wintypes.BOOL
u32.GetClientRect.argtypes = [wintypes.HWND, ctypes.POINTER(wintypes.RECT)]
gdi.CreateCompatibleDC.restype = wintypes.HDC
gdi.CreateCompatibleDC.argtypes = [wintypes.HDC]
gdi.CreateDIBSection.restype = wintypes.HBITMAP
gdi.CreateDIBSection.argtypes = [wintypes.HDC, ctypes.POINTER(BITMAPINFOHEADER), wintypes.UINT,
                                 ctypes.POINTER(ctypes.c_void_p), wintypes.HANDLE, wintypes.DWORD]
gdi.SelectObject.restype = wintypes.HANDLE
gdi.SelectObject.argtypes = [wintypes.HDC, wintypes.HANDLE]
gdi.DeleteObject.restype = wintypes.BOOL
gdi.DeleteObject.argtypes = [wintypes.HANDLE]
gdi.DeleteDC.restype = wintypes.BOOL
gdi.DeleteDC.argtypes = [wintypes.HDC]
gdi.BitBlt.restype = wintypes.BOOL
gdi.BitBlt.argtypes = [wintypes.HDC, ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_int,
                       wintypes.HDC, ctypes.c_int, ctypes.c_int, wintypes.DWORD]
k32.Sleep.argtypes = [wintypes.DWORD]

# ---- 窗口过程 ----
def wndproc(hwnd, msg, wp, lp):
    return u32.DefWindowProcA(hwnd, msg, wp, lp)

hinst = k32.GetModuleHandleA(None)
icc = ICCEX(ctypes.sizeof(ICCEX), 1)
comctl.InitCommonControlsEx(ctypes.byref(icc))

wc = WNDCLASSEXA()
wc.cbSize = ctypes.sizeof(WNDCLASSEXA)
wc.style = 3  # CS_HREDRAW|CS_VREDRAW
wc.lpfnWndProc = WNDPROC(wndproc)
wc.hInstance = hinst
wc.hbrBackground = 6  # COLOR_BTNFACE+1
wc.lpszClassName = b'HdrShotWnd'
u32.RegisterClassExA(ctypes.byref(wc))

hwnd = u32.CreateWindowExA(0, b'HdrShotWnd', b'HdrShot', 0x00CF0000, 100, 100, 420, 260,
                           None, None, hinst, None)
u32.ShowWindow(hwnd, 5)  # SW_SHOW
u32.UpdateWindow(hwnd)

lv = u32.CreateWindowExA(0, b'SysListView32', b'', 0x40000000 | 0x10000000 | 1, 10, 10, 380, 200, hwnd, None, hinst, None)
lc = LVCOLUMNA()
lc.mask = 0x0001 | 0x0002 | 0x0008
lc.fmt = 0
lc.cx = 120
lc.pszText = b'Disk'
lc.iSubItem = 0
u32.SendMessageA(lv, 0x1061, 0, ctypes.byref(lc))
lc2 = LVCOLUMNA()
lc2.mask = 0x0001 | 0x0002 | 0x0008
lc2.fmt = 0
lc2.cx = 200
lc2.pszText = b'Model'
lc2.iSubItem = 1
u32.SendMessageA(lv, 0x1061, 1, ctypes.byref(lc2))
u32.SendMessageA(lv, 0x1036, 0, 0x00000021)  # LVS_EX_GRIDLINES|FULLROWSELECT

# 行数据
class LVITEMA(ctypes.Structure):
    _fields_ = [('mask', wintypes.UINT), ('iItem', ctypes.c_int), ('iSubItem', ctypes.c_int),
                ('state', wintypes.UINT), ('stateMask', wintypes.UINT), ('pszText', ctypes.c_char_p),
                ('cchTextMax', ctypes.c_int), ('iImage', ctypes.c_int), ('lParam', ctypes.c_longlong),
                ('iIndent', ctypes.c_int), ('iGroupId', ctypes.c_int), ('cColumns', wintypes.UINT),
                ('puColumns', ctypes.c_void_p), ('piColFmt', ctypes.c_void_p), ('iGroup', ctypes.c_int)]
it = LVITEMA()
it.mask = 0x0001
it.iItem = 0
it.iSubItem = 0
it.pszText = b'PhysicalDrive0'
u32.SendMessageA(lv, 0x1007, 0, ctypes.byref(it))

u32.PeekMessageA.restype = ctypes.c_int
u32.PeekMessageA.argtypes = [ctypes.c_void_p, wintypes.HWND, wintypes.UINT, wintypes.UINT, wintypes.UINT]
u32.DispatchMessageA.restype = ctypes.c_longlong
u32.DispatchMessageA.argtypes = [ctypes.c_void_p]
u32.TranslateMessage.restype = wintypes.BOOL
u32.TranslateMessage.argtypes = [ctypes.c_void_p]

# 跑消息循环让窗口/控件绘制
class MSG(ctypes.Structure):
    _fields_ = [('hwnd', wintypes.HWND), ('message', wintypes.UINT),
                ('wParam', wintypes.WPARAM), ('lParam', wintypes.LPARAM),
                ('time', wintypes.DWORD), ('pt', wintypes.POINT)]
deadline = time.time() + 1.0
while time.time() < deadline:
    m = MSG()
    while u32.PeekMessageA(ctypes.byref(m), None, 0, 0, 1):  # PM_REMOVE
        u32.TranslateMessage(ctypes.byref(m))
        u32.DispatchMessageA(ctypes.byref(m))
    time.sleep(0.01)

# ---- 截图（含 ListView 区域）----
dc = u32.GetDC(hwnd)
mdc = gdi.CreateCompatibleDC(dc)
rc = wintypes.RECT()
u32.GetClientRect(hwnd, ctypes.byref(rc))
W, H = rc.right, rc.bottom
bih = BITMAPINFOHEADER()
bih.biSize = ctypes.sizeof(BITMAPINFOHEADER)
bih.biWidth = W
bih.biHeight = -H  # top-down
bih.biPlanes = 1
bih.biBitCount = 32
bih.biCompression = 0
bits = ctypes.c_void_p()
hbmp = gdi.CreateDIBSection(mdc, ctypes.byref(bih), 0, ctypes.byref(bits), None, 0)
gdi.SelectObject(mdc, hbmp)
gdi.BitBlt(mdc, 0, 0, W, H, dc, 0, 0, 0x00CC0020)  # SRCCOPY
data = ctypes.string_at(bits, W * H * 4)

# 分析：列头区域（y 10..30 附近是 header），统计非背景色像素（文字/边框）
# header 顶部区域（窗口客户区 10..40 是 ListView 顶部=列头）
import collections
for region, name in [((10, 10, 390, 38), 'header'), ((10, 40, 390, 200), 'rows')]:
    cnt = collections.Counter()
    for y in range(region[1], region[3]):
        for x in range(region[0], region[2]):
            off = (y * W + x) * 4
            b, g, r = data[off], data[off + 1], data[off + 2]
            cnt[(r, g, b)] += 1
    top = cnt.most_common(4)
    print('%s region distinct_colors=%d top=%s' % (name, len(cnt), top))

# 保存 BMP
row_size = ((W * 32 + 31) // 32) * 4
bmp = bytearray()
bmp += struct.pack('<2sIHHI', b'BM', 54 + row_size * H, 0, 0, 54)
bmp += struct.pack('<IiiHHIIiiII', 40, W, H, 1, 32, 0, row_size * H, 0, 0, 0, 0)
for y in range(H):
    bmp += data[y * W * 4:(y + 1) * W * 4]
with open(r'C:\Users\ganxin01\Documents\trae-work\ServerSystemTest\firpe-cleaner-native\tools\hdrtest.bmp', 'wb') as f:
    f.write(bytes(bmp))
print('saved hdrtest.bmp %dx%d' % (W, H))

gdi.DeleteObject(hbmp)
gdi.DeleteDC(mdc)
u32.ReleaseDC(hwnd, dc)
u32.DestroyWindow(hwnd)
print('done')
