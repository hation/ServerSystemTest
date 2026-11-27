#ifndef FIRPE_PATCHES_H
#define FIRPE_PATCHES_H

/*
 * patches.h - TCC 缺失 SDK 头补丁
 * TCC 自带 winapi 头缺少 commctrl.h 与 winioctl.h，
 * 这里补上 UI 骨架与后续磁盘枚举所需的类型/常量（权威值）。
 * 宏常量用 #ifndef 保护，typedef 用结构标签保护，避免重复定义。
 */

/* ===== commctrl 补丁 ===== */

#ifndef WC_LISTVIEWA
#define WC_LISTVIEWA "SysListView32"
#endif

#ifndef ICC_LISTVIEW_CLASSES
#define ICC_LISTVIEW_CLASSES 0x00000001
#endif

#ifndef _tagINITCOMMONCONTROLSEX
#define _tagINITCOMMONCONTROLSEX
typedef struct tagINITCOMMONCONTROLSEX {
    DWORD dwSize;
    DWORD dwICC;
} INITCOMMONCONTROLSEX, *LPINITCOMMONCONTROLSEX;
#endif

#ifndef InitCommonControlsEx
BOOL WINAPI InitCommonControlsEx(const INITCOMMONCONTROLSEX* picc);
#endif

#ifndef LVS_REPORT
#define LVS_REPORT 0x0001
#endif

#ifndef LVS_EX_GRIDLINES
#define LVS_EX_GRIDLINES 0x00000001
#endif
#ifndef LVS_EX_CHECKBOXES
#define LVS_EX_CHECKBOXES 0x00000004
#endif
#ifndef LVS_EX_FULLROWSELECT
#define LVS_EX_FULLROWSELECT 0x00000020
#endif

#ifndef _tagLVCOLUMNA
#define _tagLVCOLUMNA
typedef struct tagLVCOLUMNA {
    UINT mask;
    int  fmt;
    int  cx;
    LPCSTR pszText;
    int  cchTextMax;
    int  iSubItem;
    int  iImage;
    int  iOrder;
} LVCOLUMNA;
#endif

#ifndef LVCF_FMT
#define LVCF_FMT 0x0001
#endif
#ifndef LVCF_WIDTH
#define LVCF_WIDTH 0x0002
#endif
#ifndef LVCF_TEXT
/* 实测（本机 comctl32）：LVCF_FMT=0x0001、LVCF_TEXT=0x0004。
 * 历史版本曾把两者互换（TEXT=0x0001/FMT=0x0004），导致
 * LVM_INSERTCOLUMNA 时 mask 不含真实 LVCF_TEXT，列头文本从未写入，
 * 列表只能看到行数据、看不到列标题。本机验证：mask=0x0002|0x0004
 * 的列可读回文本，mask=0x0002|0x0001 的列为空。 */
#define LVCF_TEXT 0x0004
#endif
#ifndef LVCF_SUBITEM
#define LVCF_SUBITEM 0x0008
#endif

#ifndef LVCFMT_LEFT
#define LVCFMT_LEFT 0
#endif
#ifndef LVCFMT_RIGHT
#define LVCFMT_RIGHT 1
#endif

#ifndef _tagLVITEMA
#define _tagLVITEMA
typedef struct tagLVITEMA {
    UINT   mask;
    int    iItem;
    int    iSubItem;
    UINT   state;
    UINT   stateMask;
    LPCSTR pszText;
    int    cchTextMax;
    int    iImage;
    LPARAM lParam;
    int    iIndent;
    int    iGroupId;
    UINT   cColumns;
    UINT*  puColumns;
    int*   piColFmt;
    int    iGroup;
} LVITEMA;
#endif

#ifndef LVIF_TEXT
#define LVIF_TEXT 0x0001
#endif
#ifndef LVIF_STATE
#define LVIF_STATE 0x0008
#endif
#ifndef LVIF_PARAM
#define LVIF_PARAM 0x0004
#endif

#ifndef LVIS_STATEIMAGEMASK
#define LVIS_STATEIMAGEMASK 0xF000
#endif
#ifndef LVIS_CHECKED
#define LVIS_CHECKED 0x2000
#endif

#ifndef INDEXTOSTATEIMAGEMASK
#define INDEXTOSTATEIMAGEMASK(i) ((i) << 12)
#endif

#ifndef LVM_FIRST
#define LVM_FIRST 0x1000
#endif
#ifndef LVM_INSERTCOLUMNA
/* A 版建列消息：LVM_INSERTCOLUMNA = LVM_FIRST + 27 = 0x101B。
 * （0x1061 = LVM_FIRST + 97 是 LVM_INSERTCOLUMNW 的 Wide 版——用它传本文件
 * 的 ANSI 结构 LVCOLUMNA（pszText 为 char*）时，comctl32 会把 char* 当成
 * wchar_t* 读，相邻两字节拼成一个生僻汉字，于是"列头乱码"而"行文本正常"，
 * 因为行文本走的是正确的 A 版 LVM_SETITEMTEXTA。0x1001 则是 LVM_SETBKCOLOR。） */
#define LVM_INSERTCOLUMNA (LVM_FIRST + 0x1B)
#endif
#ifndef LVM_INSERTITEMA
#define LVM_INSERTITEMA   (LVM_FIRST + 0x07)
#endif
#ifndef LVM_SETITEMSTATE
#define LVM_SETITEMSTATE  (LVM_FIRST + 0x2B)
#endif
#ifndef LVM_GETITEMCOUNT
#define LVM_GETITEMCOUNT  (LVM_FIRST + 0x04)
#endif
#ifndef LVM_DELETEALLITEMS
#define LVM_DELETEALLITEMS (LVM_FIRST + 0x09)
#endif
#ifndef LVM_SETEXTENDEDLISTVIEWSTYLE
#define LVM_SETEXTENDEDLISTVIEWSTYLE (LVM_FIRST + 0x36)
#endif
#ifndef LVM_GETITEMSTATE
#define LVM_GETITEMSTATE (LVM_FIRST + 0x2C)
#endif
#ifndef LVM_SETITEMTEXTA
/* 实测：0x2D(+45) 是 LVM_GETITEMTEXTA（会把现有文本拷进 pszText 缓冲，
 * 子列文本永远写不进去），真正的 SETITEMTEXTA 是 0x2E(+46)。 */
#define LVM_SETITEMTEXTA (LVM_FIRST + 0x2E)
#endif
#ifndef LVM_GETITEMTEXTA
#define LVM_GETITEMTEXTA (LVM_FIRST + 0x2D)
#endif
#ifndef LVM_GETHEADER
#define LVM_GETHEADER    (LVM_FIRST + 0x1F)
#endif
#ifndef LVM_GETCOLUMNA
/* A 版读列头文字：LVM_GETCOLUMNA = LVM_FIRST + 25 = 0x1019。
 * （0x105F = LVM_FIRST + 95 是 LVM_GETCOLUMNW 的 Wide 版，勿混用。） */
#define LVM_GETCOLUMNA   (LVM_FIRST + 0x19)
#endif
#ifndef LVM_SETTEXTCOLOR
/* 实测（本机 comctl32 v6 无 manifest，A/W 一致）：LVM_SETTEXTCOLOR 是
 * 0x1024（LVM_FIRST+0x24）。注意 0x1004 是 LVM_GETITEMCOUNT（已实测：
 * 插入 2 行后 LVM_GETITEMCOUNT(0x1004) 返回 2），两者绝不能混用——
 * 用 0x1004 设置颜色会把 COLORREF 发给取行数消息，且破坏行数统计。
 * 用 0x1024 设置后 LVM_GETTEXTCOLOR(0x1023) 可读回设置值。 */
#define LVM_SETTEXTCOLOR (LVM_FIRST + 0x24)
#endif
#ifndef LVM_GETTEXTCOLOR
#define LVM_GETTEXTCOLOR (LVM_FIRST + 0x23)
#endif
#ifndef LVM_SETBKCOLOR
/* 0x1001：注意与 LVM_INSERTCOLUMNA（0x101B）区分——0x1001 是 SETBKCOLOR，
 * 建列消息是 0x101B（见上），两者绝不能混用。
 * 实测：0x1001 设置后 LVM_GETBKCOLOR(0x1000) 可读回设置值。 */
#define LVM_SETBKCOLOR   (LVM_FIRST + 0x01)
#endif

/* ===== SysHeader32 (HDM_*) 补丁（列头渲染兼容） =====
 * 消息值以本机 comctl32 5.82（无 manifest，v5 行为，与 FirPE 一致）实测为准
 * （逐候选消息号发 COLORREF + 像素级验证渲染，32/64 位一致）：
 *   HDM_GETITEMCOUNT = 0x1200、HDM_GETITEMA = 0x1203、HDM_GETITEMW = 0x120B
 *   （均与官方 SDK 值一致；0x120B 是指针消息，读回列头文字请用 LVM_GETCOLUMNA）
 * 颜色消息实测结论：
 *   0x1208：文本色消息——lParam≠0 存色（返回 0），lParam=0 读回已存色。
 *            但对默认列头渲染无可见效果（设红后无红像素）——comctl32 5.82
 *            列头文字色固定为系统默认（黑），此消息仅存储、不生效。
 *   0x1209：非颜色消息（发送无害、无效果；官方值为 HDM_INDEXTOORDER）。
 *           历史 patches.h 曾把 HDM_SETTEXTCOLOR 错标为 0x1209（无效）。
 *   0x120A/0x120B/0x120C：HDM_INSERTITEMW / HDM_GETITEMW / HDM_SETITEMW
 *            指针消息——传 COLORREF 实测崩溃（0xC0000005 访问违规），严禁
 *            调用。历史 patches.h 曾把 HDM_SETBKCOLOR 错标为 0x120A（崩溃
 *            源）；0x120A 传 COLORREF 是否崩溃取决于该值是否为可读地址，
 *            表现为"间歇性崩溃"（实测 0xFF 崩、0xFF0000 返回 -1）。
 *   0x120D..0x1215：均无可见改色效果（0x1213 原样返回 lParam）。
 * 结论：不存在可用/生效的 HDM_SETBKCOLOR（能改列头背景色的消息）；
 * HDM_SETTEXTCOLOR 仅 0x1208 可存储文本色（无可见效果、无害）。
 * 列头文字默认即系统黑，可见性无需改色。 */

#ifndef HDM_FIRST
#define HDM_FIRST 0x1200
#endif
#ifndef HDM_GETITEMCOUNT
#define HDM_GETITEMCOUNT (HDM_FIRST)
#endif
#ifndef HDM_GETITEMA
#define HDM_GETITEMA     (HDM_FIRST + 0x03)
#endif
#ifndef HDM_GETITEMW
/* 0x120B 是 HDM_GETITEMW（lParam=HDITEM*，往 pszText 指向的 WCHAR 缓冲写
 * UTF-16 文本；本机实测超量复制相邻内存，读回列头文字不可靠，
 * 验证列头写入请用 LVM_GETCOLUMNA，勿用本消息读回）。 */
#define HDM_GETITEMW     (HDM_FIRST + 0x0B)
#endif
#ifndef HDM_SETTEXTCOLOR
/* 0x1208（HDM_FIRST+0x08）：实测可存储/读回列头文本色（lParam≠0 存色、
 * 返回 0；lParam=0 读回已存色）。但对 comctl32 5.82 的默认列头渲染无可见
 * 效果（像素级验证设红后无红像素），列头文字默认即系统黑——发送黑字仅为
 * 兜底、无害。 */
#define HDM_SETTEXTCOLOR (HDM_FIRST + 0x08)
#endif
#ifndef HDM_GETTEXTCOLOR
/* 与 HDM_SETTEXTCOLOR 同号（0x1208）：lParam=0 读回已存文本色（实测） */
#define HDM_GETTEXTCOLOR (HDM_FIRST + 0x08)
#endif
/* HDM_SETBKCOLOR：不存在安全可用值（0x120A/0x120B/0x120C 传 COLORREF 实测
 * 崩溃——它们分别是 HDM_INSERTITEMW/GETITEMW/SETITEMW 指针消息；0x120D..
 * 0x1215 实测无改色效果）。故意不定义该宏：列头背景保持系统默认，
 * 黑字在系统背景上可见。 */

#ifndef HDI_TEXT
/* 实测：本机 comctl32 以 0x0002 为文本读写 mask（插列/读回均验证），
 * 保持与 LVCF_TEXT=0x0004 不同，勿合并修改 */
#define HDI_TEXT 0x0002
#endif

/* ===== kernel32 补丁（TCC 头缺 WideCharToMultiByte / CP_ACP） ===== */
#ifndef CP_ACP
#define CP_ACP 0
#endif
#ifndef WideCharToMultiByte
int WINAPI WideCharToMultiByte(UINT CodePage, DWORD dwFlags,
                               LPCWSTR lpWideCharStr, int cchWideChar,
                               LPSTR lpMultiByteStr, int cbMultiByte,
                               LPCSTR lpDefaultChar, LPBOOL lpUsedDefaultChar);
#endif
#ifndef _tagHDITEM
#define _tagHDITEM
typedef struct tagHDITEM {
    UINT   mask;
    int    cxy;
    LPCSTR pszText;
    HANDLE hbm;
    int    cchTextMax;
    int    fmt;
    LPARAM lParam;
    int    iImage;
    int    iOrder;
} HDITEM;
#endif
#ifndef LVM_ENSUREVISIBLE
#define LVM_ENSUREVISIBLE (LVM_FIRST + 0x13)
#endif

/* ===== winioctl 补丁 ===== */

/* ===== GetDriveTypeA 返回值补丁（driver.c 盘符扫描用） ===== */

#ifndef DRIVE_UNKNOWN
#define DRIVE_UNKNOWN 0
#endif
#ifndef DRIVE_NO_ROOT_DIR
#define DRIVE_NO_ROOT_DIR 1
#endif
#ifndef DRIVE_REMOVABLE
#define DRIVE_REMOVABLE 2
#endif
#ifndef DRIVE_FIXED
#define DRIVE_FIXED 3
#endif
#ifndef DRIVE_REMOTE
#define DRIVE_REMOTE 4
#endif
#ifndef DRIVE_CDROM
#define DRIVE_CDROM 5
#endif
#ifndef DRIVE_RAMDISK
#define DRIVE_RAMDISK 6
#endif

#ifndef IOCTL_STORAGE_QUERY_PROPERTY
#define IOCTL_STORAGE_QUERY_PROPERTY  0x002D1400
#endif
#ifndef IOCTL_STORAGE_GET_DEVICE_NUMBER
#define IOCTL_STORAGE_GET_DEVICE_NUMBER 0x002D0400
#endif
#ifndef IOCTL_DISK_GET_DRIVE_GEOMETRY
#define IOCTL_DISK_GET_DRIVE_GEOMETRY  0x00070000
#endif
#ifndef IOCTL_DISK_GET_DRIVE_GEOMETRY_EX
#define IOCTL_DISK_GET_DRIVE_GEOMETRY_EX 0x000700A0
#endif
#ifndef IOCTL_VOLUME_GET_VOLUME_DISK_EXTENTS
#define IOCTL_VOLUME_GET_VOLUME_DISK_EXTENTS 0x00560000
#endif

#ifndef StorageDeviceProperty
#define StorageDeviceProperty 0
#endif
#ifndef PropertyStandardQuery
#define PropertyStandardQuery 0
#endif

#ifndef _tagSTORAGE_PROPERTY_QUERY
#define _tagSTORAGE_PROPERTY_QUERY
typedef struct _STORAGE_PROPERTY_QUERY {
    ULONG PropertyId;
    ULONG QueryType;
    UCHAR AdditionalParameters[1];
} STORAGE_PROPERTY_QUERY;
#endif

#ifndef _tagSTORAGE_DEVICE_DESCRIPTOR
#define _tagSTORAGE_DEVICE_DESCRIPTOR
typedef struct _STORAGE_DEVICE_DESCRIPTOR {
    ULONG  Version;
    ULONG  Size;
    UCHAR  DeviceType;
    UCHAR  DeviceTypeModifier;
    BOOLEAN RemovableMedia;
    BOOLEAN CommandQueueing;
    ULONG  VendorIdOffset;
    ULONG  ProductIdOffset;
    ULONG  SerialNumberOffset;
    int    BusType;
    ULONG  RawProperties[1];
} STORAGE_DEVICE_DESCRIPTOR;
#endif

#ifndef BusTypeUnknown
#define BusTypeUnknown 0x00
#endif
#ifndef BusTypeScsi
#define BusTypeScsi 0x01
#endif
#ifndef BusTypeAtapi
#define BusTypeAtapi 0x02
#endif
#ifndef BusTypeAta
#define BusTypeAta 0x03
#endif
#ifndef BusType1394
#define BusType1394 0x04
#endif
#ifndef BusTypeSsa
#define BusTypeSsa 0x05
#endif
#ifndef BusTypeFibre
#define BusTypeFibre 0x06
#endif
#ifndef BusTypeUsb
#define BusTypeUsb 0x08
#endif
#ifndef BusTypeRAID
#define BusTypeRAID 0x09
#endif
#ifndef BusTypeiScsi
#define BusTypeiScsi 0x0A
#endif
#ifndef BusTypeSas
#define BusTypeSas 0x0B
#endif
#ifndef BusTypeVirtual
#define BusTypeVirtual 0x0E
#endif

#ifndef _tagDISK_GEOMETRY
#define _tagDISK_GEOMETRY
typedef struct _DISK_GEOMETRY {
    LARGE_INTEGER Cylinders;
    DWORD MediaType;
    DWORD TracksPerCylinder;
    DWORD SectorsPerTrack;
    DWORD BytesPerSector;
} DISK_GEOMETRY;
#endif

#ifndef _tagDISK_GEOMETRY_EX
#define _tagDISK_GEOMETRY_EX
typedef struct _DISK_GEOMETRY_EX {
    DISK_GEOMETRY Geometry;
    LARGE_INTEGER DiskSize;
    UCHAR Data[1];
} DISK_GEOMETRY_EX;
#endif

#ifndef FixedHardDiskMedia
#define FixedHardDiskMedia 0x0C
#endif
#ifndef CD_ROM
#define CD_ROM 0x16
#endif

#ifndef _tagDISK_EXTENT
#define _tagDISK_EXTENT
typedef struct _DISK_EXTENT {
    DWORD DiskNumber;
    LARGE_INTEGER StartingOffset;
    LARGE_INTEGER ExtentLength;
} DISK_EXTENT;
#endif

#ifndef _tagVOLUME_DISK_EXTENTS
#define _tagVOLUME_DISK_EXTENTS
typedef struct _VOLUME_DISK_EXTENTS {
    DWORD NumberOfDiskExtents;
    DISK_EXTENT Extents[1];
} VOLUME_DISK_EXTENTS;
#endif

#ifndef _tagSTORAGE_DEVICE_NUMBER
#define _tagSTORAGE_DEVICE_NUMBER
typedef struct _STORAGE_DEVICE_NUMBER {
    DWORD DeviceType;
    DWORD DeviceNumber;
    DWORD PartitionNumber;
} STORAGE_DEVICE_NUMBER;
#endif

#endif /* FIRPE_PATCHES_H */
