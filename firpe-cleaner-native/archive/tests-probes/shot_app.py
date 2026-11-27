# shot_app.py - 启动真实 FirpeCleaner64.exe，截图分析 ListView 列头区域
import subprocess, time, struct, collections, ctypes
from ctypes import wintypes

u32 = ctypes.WinDLL('user32', use_last_error=True)
gdi = ctypes.WinDLL('gdi32', use_last_error=True)
k32 = ctypes.WinDLL('kernel32', use_last_error=True)

class BITMAPINFOHEADER(ctypes.Structure):
    _fields_ = [('biSize', wintypes.DWORD), ('biWidth', ctypes.c_long), ('biHeight', ctypes.c_long),
                ('biPlanes', wintypes.WORD), ('biBitCount', wintypes.WORD),
                ('biCompression', wintypes.DWORD), ('biSizeImage', wintypes.DWORD),
                ('biXPelsPerMeter', ctypes.c_long), ('biYPelsPerMeter', ctypes.c_long),
                ('biClrUsed', wintypes.DWORD), ('biClrImportant', wintypes.DWORD)]
u32.FindWindowA.restype = wintypes.HWND
u32.FindWindowA.argtypes = [ctypes.c_char_p, ctypes.c_char_p]
u32.GetWindowRect.restype = wintypes.BOOL
u32.GetWindowRect.argtypes = [wintypes.HWND, ctypes.POINTER(wintypes.RECT)]
u32.GetDC.restype = wintypes.HDC
u32.GetDC.argtypes = [wintypes.HWND]
u32.ReleaseDC.restype = ctypes.c_int
u32.ReleaseDC.argtypes = [wintypes.HWND, wintypes.HDC]
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

exe = r'C:\Users\ganxin01\Documents\trae-work\ServerSystemTest\firpe-cleaner-native\dist\FirpeCleaner64.exe'
p = subprocess.Popen([exe])
hwnd = None
for _ in range(50):
    hwnd = u32.FindWindowA(b'FirpeCleanerWndClass', None)
    if hwnd:
        break
    time.sleep(0.1)
if not hwnd:
    print('window not found'); p.kill(); raise SystemExit(1)
time.sleep(0.8)
rc = wintypes.RECT()
u32.GetWindowRect(hwnd, ctypes.byref(rc))
W, H = rc.right - rc.left, rc.bottom - rc.top
print('window rect %dx%d at (%d,%d)' % (W, H, rc.left, rc.top))

# 客户区截图
dc = u32.GetDC(hwnd)
mdc = gdi.CreateCompatibleDC(dc)
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

# ListView 区域：客户区 (10,10)-(890,400) 附近；列头在顶部 ~20px
for region, name in [((10, 10, 890, 40), 'header'), ((10, 40, 890, 400), 'rows')]:
    cnt = collections.Counter()
    for y in range(region[1], region[3]):
        for x in range(region[0], region[2]):
            off = (y * W + x) * 4
            cnt[(data[off + 2], data[off + 1], data[off])] += 1
    top = cnt.most_common(4)
    black = sum(v for (r, g, b), v in cnt.items() if r < 80 and g < 80 and b < 80)
    nonwhite = sum(v for (r, g, b), v in cnt.items() if not (r > 235 and g > 235 and b > 235))
    print('%s distinct=%d black_px=%d nonwhite=%d top=%s' % (name, len(cnt), black, nonwhite, top))

row_size = ((W * 32 + 31) // 32) * 4
bmp = bytearray()
bmp += struct.pack('<2sIHHI', b'BM', 54 + row_size * H, 0, 0, 54)
bmp += struct.pack('<IiiHHIIiiII', 40, W, H, 1, 32, 0, row_size * H, 0, 0, 0, 0)
for y in range(H):
    bmp += data[y * W * 4:(y + 1) * W * 4]
with open(r'C:\Users\ganxin01\Documents\trae-work\ServerSystemTest\firpe-cleaner-native\tools\app_shot.bmp', 'wb') as f:
    f.write(bytes(bmp))
print('saved app_shot.bmp')

gdi.DeleteObject(hbmp)
gdi.DeleteDC(mdc)
u32.ReleaseDC(hwnd, dc)
p.terminate()
p.wait(timeout=5)
print('done')
