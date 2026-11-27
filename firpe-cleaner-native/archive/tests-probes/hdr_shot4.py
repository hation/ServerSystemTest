# hdr_shot4.py - 独立 SysHeader32：HDM_INSERTITEMA + 截图，验证 header 文字渲染环境
import ctypes, time, struct, collections
from ctypes import wintypes

u32 = ctypes.WinDLL('user32', use_last_error=True)
gdi = ctypes.WinDLL('gdi32', use_last_error=True)
comctl = ctypes.WinDLL('comctl32', use_last_error=True)
k32 = ctypes.WinDLL('kernel32', use_last_error=True)

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
class HDITA(ctypes.Structure):
    _fields_ = [('mask', wintypes.UINT), ('cxy', ctypes.c_int), ('pszText', ctypes.c_char_p),
                ('hbm', ctypes.c_void_p), ('cchTextMax', ctypes.c_int), ('fmt', ctypes.c_int),
                ('lParam', ctypes.c_longlong), ('iImage', ctypes.c_int), ('iOrder', ctypes.c_int),
                ('type', wintypes.UINT), ('pvFilter', ctypes.c_void_p), ('state', wintypes.UINT)]
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
u32.PeekMessageA.restype = ctypes.c_int
u32.PeekMessageA.argtypes = [ctypes.c_void_p, wintypes.HWND, wintypes.UINT, wintypes.UINT, wintypes.UINT]
u32.DispatchMessageA.restype = ctypes.c_longlong
u32.DispatchMessageA.argtypes = [ctypes.c_void_p]
u32.TranslateMessage.restype = wintypes.BOOL
u32.TranslateMessage.argtypes = [ctypes.c_void_p]
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

def wndproc(hwnd, msg, wp, lp):
    return u32.DefWindowProcA(hwnd, msg, wp, lp)

hinst = k32.GetModuleHandleA(None)
icc = ICCEX(ctypes.sizeof(ICCEX), 1)
comctl.InitCommonControlsEx(ctypes.byref(icc))
wc = WNDCLASSEXA()
wc.cbSize = ctypes.sizeof(WNDCLASSEXA)
wc.style = 3
wc.lpfnWndProc = WNDPROC(wndproc)
wc.hInstance = hinst
wc.hbrBackground = 6
wc.lpszClassName = b'HdrShotWnd4'
u32.RegisterClassExA(ctypes.byref(wc))
hwnd = u32.CreateWindowExA(0, b'HdrShotWnd4', b'HdrShot4', 0x00CF0000, 100, 100, 420, 120, None, None, hinst, None)
u32.ShowWindow(hwnd, 5)
u32.UpdateWindow(hwnd)

# 独立 SysHeader32（HDS_BUTTONS=2 才有按钮效果；HDS_HORZ=0）
hdr = u32.CreateWindowExA(0, b'SysHeader32', b'', 0x40000000 | 0x10000000 | 2, 10, 10, 380, 30, hwnd, None, hinst, None)
print('hdr=%x' % hdr)

# HDM_INSERTITEMA 候选：0x120E（标准）
hd = HDITA()
hd.mask = 0x0002 | 0x0004  # HDI_TEXT | HDI_FORMAT
hd.cxy = 100
hd.pszText = b'Disk'
hd.fmt = 0
r1 = u32.SendMessageA(hdr, 0x120E, 0, ctypes.byref(hd))
print('HDM_INSERTITEMA@0x120E ret=%d' % r1)
hd2 = HDITA()
hd2.mask = 0x0002 | 0x0004
hd2.cxy = 150
hd2.pszText = b'Model'
hd2.fmt = 0
r2 = u32.SendMessageA(hdr, 0x120E, 1, ctypes.byref(hd2))
print('HDM_INSERTITEMA@0x120E ret2=%d' % r2)
print('cols=%d' % u32.SendMessageA(hdr, 0x1200, 0, 0))

# 读回
for i in range(2):
    buf = ctypes.create_string_buffer(128)
    g = HDITA()
    g.mask = 0x0002
    g.pszText = buf
    g.cchTextMax = 128
    rr = u32.SendMessageA(hdr, 0x1203, i, ctypes.byref(g))
    print('  GETITEMA col %d ret=%d text=%r' % (i, rr, buf.value))

# 消息循环 + 截图
class MSG(ctypes.Structure):
    _fields_ = [('hwnd', wintypes.HWND), ('message', wintypes.UINT),
                ('wParam', wintypes.WPARAM), ('lParam', wintypes.LPARAM),
                ('time', wintypes.DWORD), ('pt', wintypes.POINT)]
deadline = time.time() + 1.0
while time.time() < deadline:
    m = MSG()
    while u32.PeekMessageA(ctypes.byref(m), None, 0, 0, 1):
        u32.TranslateMessage(ctypes.byref(m))
        u32.DispatchMessageA(ctypes.byref(m))
    time.sleep(0.01)

dc = u32.GetDC(hwnd)
mdc = gdi.CreateCompatibleDC(dc)
rc = wintypes.RECT()
u32.GetClientRect(hwnd, ctypes.byref(rc))
W, H = rc.right, rc.bottom
bih = BITMAPINFOHEADER()
bih.biSize = ctypes.sizeof(BITMAPINFOHEADER)
bih.biWidth = W
bih.biHeight = -H
bih.biPlanes = 1
bih.biBitCount = 32
bih.biCompression = 0
bits = ctypes.c_void_p()
hbmp = gdi.CreateDIBSection(mdc, ctypes.byref(bih), 0, ctypes.byref(bits), None, 0)
gdi.SelectObject(mdc, hbmp)
gdi.BitBlt(mdc, 0, 0, W, H, dc, 0, 0, 0x00CC0020)
data = ctypes.string_at(bits, W * H * 4)
cnt = collections.Counter()
for y in range(8, 44):
    for x in range(8, 392):
        off = (y * W + x) * 4
        cnt[(data[off + 2], data[off + 1], data[off])] += 1
black = sum(v for (r, g, b), v in cnt.items() if r < 80 and g < 80 and b < 80)
print('header area distinct=%d black_px=%d top=%s' % (len(cnt), black, cnt.most_common(5)))
row_size = ((W * 32 + 31) // 32) * 4
bmp = bytearray()
bmp += struct.pack('<2sIHHI', b'BM', 54 + row_size * H, 0, 0, 54)
bmp += struct.pack('<IiiHHIIiiII', 40, W, H, 1, 32, 0, row_size * H, 0, 0, 0, 0)
for y in range(H):
    bmp += data[y * W * 4:(y + 1) * W * 4]
with open(r'C:\Users\ganxin01\Documents\trae-work\ServerSystemTest\firpe-cleaner-native\tools\hdrtest4.bmp', 'wb') as f:
    f.write(bytes(bmp))
print('saved hdrtest4.bmp')
gdi.DeleteObject(hbmp)
gdi.DeleteDC(mdc)
u32.ReleaseDC(hwnd, dc)
u32.DestroyWindow(hwnd)
print('done')
