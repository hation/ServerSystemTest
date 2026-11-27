/* disks.c - 磁盘枚举模块（纯 Win32 API，WinPE 兼容，无 WMI）
 *
 * 枚举策略：注册表 HKLM\SYSTEM\CurrentControlSet\Services\disk\Enum（提供型号/盘号）
 *           与 \\.\PhysicalDrive0..31 探测（diskpart 访问磁盘的同一接口）无条件合并，
 *           按盘号去重。RAID 卷（如 ps3stor 驱动暴露的 VD）挂在厂商驱动设备枚举下，
 *           不在 disk\Enum，仍能被 PhysicalDrive 探测发现——对齐 diskpart 的枚举接口。
 * 每盘查询：
 *   IOCTL_STORAGE_QUERY_PROPERTY     → 型号 / 总线类型 / 可移动标志
 *   IOCTL_DISK_GET_DRIVE_GEOMETRY_EX → 总容量 / 介质类型（是否固定硬盘）
 *   IOCTL_VOLUME_GET_VOLUME_DISK_EXTENTS + GetDiskFreeSpaceExA → 剩余容量
 * 排除规则（命中第一个作为原因，系统盘不排除）：
 *   USB 总线 → "Excluded: USB removable"
 *   可移动介质（RemovableMedia 标志）→ "Excluded: removable media"
 *   明确的可移动/光驱介质类型（MediaType == RemovableMedia/CD_ROM）
 *     → "Excluded: removable / CD / DVD"
 *   总容量 < 1GB → "Excluded: size < 1GB"
 *   其余 → "Cleanable"
 * 注：MediaType 取自 IOCTL_DISK_GET_DRIVE_GEOMETRY_EX，部分虚拟化/厂商驱动会返回
 *   垃圾值（本机虚拟化 SCSI 驱动返回 0xC，而 WMI 报 "Fixed hard disk media"），
 *   故只对明确的 RemovableMedia/CD_ROM 类型判排除，与 C# 旧版（WMI MediaType
 *   字符串匹配 Removable/CD/DVD）行为一致。
 */
#include <windows.h>
#include <stdio.h>
#include <string.h>
#include "app.h"     /* windows.h + patches.h */
#include "disks.h"

/* patches.h 未定义 BusTypeSata/BusTypeNVMe（后者 Win10 SDK 才新增），此处补上。
 * 注意：MEDIA_TYPE 的 RemovableMedia 常量与 STORAGE_DEVICE_DESCRIPTOR 的字段同名，
 * 不能 #define RemovableMedia（会把 d->RemovableMedia 展开成 d->0x0B 导致编译失败），
 * 这里用别名 MEDIA_TYPE_REMOVABLE 指代 0x0B */
#ifndef BusTypeSata
#define BusTypeSata 0x0C
#endif
#ifndef BusTypeNVMe
#define BusTypeNVMe 0x11
#endif
#ifndef MEDIA_TYPE_REMOVABLE
#define MEDIA_TYPE_REMOVABLE 0x0B
#endif

/* 总线类型 → 文本（ASCII） */
static const char* bus_type_text(int bus)
{
    switch (bus) {
    case BusTypeUnknown: return "Unknown";
    case BusTypeScsi:    return "SCSI";
    case BusTypeAtapi:   return "ATAPI";
    case BusTypeAta:     return "ATA";
    case BusType1394:    return "1394";
    case BusTypeSsa:     return "SSA";
    case BusTypeFibre:   return "Fibre";
    case BusTypeUsb:     return "USB";
    case BusTypeRAID:    return "RAID";
    case BusTypeiScsi:   return "iSCSI";
    case BusTypeSas:     return "SAS";
    case BusTypeSata:    return "SATA";
    case BusTypeVirtual: return "Virtual";
    case BusTypeNVMe:    return "NVMe";
    default:             return "Unknown";
    }
}

/* 从缓冲区内偏移指向的字符串复制到 dst，去尾部空格；
 * src 为空/越界则输出空串；按缓冲区末尾兜底，防止越界读 */
static void copy_string(char* dst, int dstLen, const char* src, const char* bufEnd)
{
    int i = 0;
    if (!src || src >= bufEnd) { dst[0] = '\0'; return; }
    while (i < dstLen - 1 && (src + i) < bufEnd && src[i]) {
        dst[i] = src[i];
        i++;
    }
    dst[i] = '\0';
    while (i > 0 && dst[i - 1] == ' ') dst[--i] = '\0';   /* 去尾部空格 */
}

/* 型号：优先 ProductIdOffset，其次 VendorIdOffset，都无则留空 */
static void get_model(char* out, int outLen, const char* buf, int bufSize)
{
    const STORAGE_DEVICE_DESCRIPTOR* d = (const STORAGE_DEVICE_DESCRIPTOR*)buf;
    const char* src = NULL;
    if (d->ProductIdOffset)     src = buf + d->ProductIdOffset;
    else if (d->VendorIdOffset) src = buf + d->VendorIdOffset;
    copy_string(out, outLen, src, buf + bufSize);
}

/* 从注册表设备路径串末尾解析盘号，如 "\\\\.\PHYSICALDRIVE0" → 0；失败返回 -1 */
static int parse_disk_number(const char* path)
{
    const char* lastDigit = NULL;
    int len = 0, k, num = 0;
    const char* p = path;
    while (*p) {
        if (*p >= '0' && *p <= '9') {
            if (!lastDigit) lastDigit = p;
            len++;
        } else {
            lastDigit = NULL;
            len = 0;
        }
        p++;
    }
    if (!lastDigit) return -1;
    for (k = 0; k < len; k++) num = num * 10 + (lastDigit[k] - '0');
    return num;
}

/* 累加本盘逻辑卷的剩余字节；返回是否至少成功累加一次（false 则剩余保持 -1） */
static int accumulate_free(long long* freeBytes, int diskNumber)
{
    DWORD drives = GetLogicalDrives();
    int c, hit = 0;
    for (c = 'A'; c <= 'Z'; c++) {
        char dev[8], root[4];
        HANDLE h;
        BYTE extBuf[4096];   /* 可容纳约 127 个 extent；跨盘卷多 extent 也够 */
        DWORD bytes = 0;
        VOLUME_DISK_EXTENTS* ve;
        DWORD e;

        if (!(drives & (1u << (c - 'A')))) continue;   /* 该盘符不存在 */
        sprintf(dev, "\\\\.\\%c:", c);
        h = CreateFileA(dev, 0, FILE_SHARE_READ | FILE_SHARE_WRITE, NULL,
                        OPEN_EXISTING, 0, NULL);
        if (h == INVALID_HANDLE_VALUE) continue;       /* 打不开（如无介质 CD），跳过 */

        if (DeviceIoControl(h, IOCTL_VOLUME_GET_VOLUME_DISK_EXTENTS, NULL, 0,
                            extBuf, sizeof(extBuf), &bytes, NULL)
            && bytes >= sizeof(VOLUME_DISK_EXTENTS)) {
            ve = (VOLUME_DISK_EXTENTS*)extBuf;
            for (e = 0; e < ve->NumberOfDiskExtents; e++) {
                if ((int)ve->Extents[e].DiskNumber == diskNumber) {
                    ULARGE_INTEGER avail;
                    sprintf(root, "%c:\\", c);
                    if (GetDiskFreeSpaceExA(root, &avail, NULL, NULL)) {
                        *freeBytes += (long long)avail.QuadPart;
                        hit = 1;
                    }
                }
            }
        }
        CloseHandle(h);
    }
    return hit;
}

/* 查询并填充单个物理盘；成功返回 1，失败（打不开设备）返回 0 */
static int query_one_disk(DiskInfo* info, int diskNumber)
{
    char dev[32];
    char b[256];
    HANDLE h;
    STORAGE_PROPERTY_QUERY q;
    BYTE sdBuf[512];
    DWORD bytes = 0;
    DISK_GEOMETRY_EX dge;
    int busType = BusTypeUnknown;
    int removable = 0;
    int mediaType = 0;
    int geomOk = 0;     /* Geometry 查询是否成功；失败时不得用 SizeGB 判排除 */
    long long freeBytes = 0;

    sprintf(dev, "\\\\.\\PhysicalDrive%d", diskNumber);
    h = CreateFileA(dev, 0, FILE_SHARE_READ | FILE_SHARE_WRITE, NULL,
                    OPEN_EXISTING, 0, NULL);
    if (h == INVALID_HANDLE_VALUE) {
        sprintf(b, "[D] disk %d: open FAILED, err=%lu",
                diskNumber, (unsigned long)GetLastError());
        BootLog(b);
        return 0;   /* 该盘号不存在 */
    }

    memset(info, 0, sizeof(*info));
    info->Number = diskNumber;
    info->FreeGB = -1;                          /* 默认未知，查不到保持 -1 */

    /* 1) 型号 / 总线 / 可移动标志 */
    memset(&q, 0, sizeof(q));
    q.PropertyId = StorageDeviceProperty;
    q.QueryType  = PropertyStandardQuery;
    if (DeviceIoControl(h, IOCTL_STORAGE_QUERY_PROPERTY, &q, sizeof(q),
                        sdBuf, sizeof(sdBuf), &bytes, NULL)
        && bytes >= sizeof(STORAGE_DEVICE_DESCRIPTOR)) {
        STORAGE_DEVICE_DESCRIPTOR* d = (STORAGE_DEVICE_DESCRIPTOR*)sdBuf;
        busType   = d->BusType;
        removable = d->RemovableMedia ? 1 : 0;
        get_model(info->Model, sizeof(info->Model), (const char*)sdBuf, (int)sizeof(sdBuf));
    }
    strcpy(info->Bus, bus_type_text(busType));

    /* 2) 总容量 + 介质类型（Geometry 24 字节 + DiskSize 8 字节，跨 x86/x64 一致） */
    memset(&dge, 0, sizeof(dge));
    if (DeviceIoControl(h, IOCTL_DISK_GET_DRIVE_GEOMETRY_EX, NULL, 0,
                        &dge, sizeof(dge), &bytes, NULL)
        && bytes >= (DWORD)(sizeof(DISK_GEOMETRY) + sizeof(LARGE_INTEGER))) {
        info->SizeGB = (long long)(dge.DiskSize.QuadPart / (1024LL * 1024 * 1024));
        mediaType = (int)dge.Geometry.MediaType;
        geomOk = 1;
    }

    /* 3) 排除判定（优先级从高到低，命中第一个作为原因；系统盘不排除）
     * MediaType 若为未知/垃圾值（本机虚拟化 SCSI 驱动返回 0xC，WMI 却报
     * "Fixed hard disk media"），只对明确的 RemovableMedia/CD_ROM 判排除，
     * 与 C# 旧版（WMI MediaType 匹配 Removable/CD/DVD）行为一致 */
    if (busType == BusTypeUsb)
        { strcpy(info->Status, "Excluded: USB removable"); info->IsExcluded = 1; }
    else if (removable)
        { strcpy(info->Status, "Excluded: removable media"); info->IsExcluded = 1; }
    else if (mediaType == CD_ROM || mediaType == MEDIA_TYPE_REMOVABLE)
        { strcpy(info->Status, "Excluded: removable / CD / DVD"); info->IsExcluded = 1; }
    /* 容量判断仅在 Geometry 查询成功后进行：查询失败时 SizeGB=0，
     * 不能据此误排除（否则可能错杀查询异常的系统盘），保守放行 */
    else if (geomOk && info->SizeGB < 1)
        { strcpy(info->Status, "Excluded: size < 1GB"); info->IsExcluded = 1; }
    else
        { strcpy(info->Status, "Cleanable"); }

    /* 4) 剩余容量（尽力而为；IOCTL_VOLUME 失败/无匹配卷时保持 -1） */
    if (accumulate_free(&freeBytes, diskNumber))
        info->FreeGB = (long long)(freeBytes / (1024LL * 1024 * 1024));

    sprintf(b, "[D] disk %d: bus=%d rem=%d media=%d sizeGB=%lld geom=%d status=%s",
            diskNumber, busType, removable, mediaType,
            (long long)info->SizeGB, geomOk, info->Status);
    BootLog(b);

    CloseHandle(h);
    return 1;
}

/* 盘号是否已产出过（去重用）；同一盘号只保留第一次 */
static int is_number_seen(const int* seen, int seenCount, int num)
{
    int i;
    for (i = 0; i < seenCount; i++)
        if (seen[i] == num) return 1;
    return 0;
}

/* 枚举物理磁盘；返回数量，<0 表示失败（注册表与探测都一无所获）
 * 合并策略：注册表 disk\Enum（提供型号/盘号信息）与 \\.\PhysicalDrive0..31 探测
 * （diskpart 的同一接口）无条件执行，按盘号去重合并。RAID 卷（ps3stor 驱动暴露
 * 的 VD）不在 disk\Enum，但 CreateFileA("\\.\PhysicalDriveN") 能打开（diskpart
 * 能看到即能打开），故探测阶段必然枚举到。 */
int EnumerateDisks(DiskInfo* out, int maxCount)
{
    int count = 0;
    int seen[64];
    int seenCount = 0;
    char b[256];

    /* 信息源 1：注册表 disk\Enum（提供型号/盘号信息；只影响信息，不决定成败） */
    HKEY hk = NULL;
    LONG lr = RegOpenKeyExA(HKEY_LOCAL_MACHINE,
        "SYSTEM\\CurrentControlSet\\Services\\disk\\Enum", 0, KEY_READ, &hk);
    sprintf(b, "[D] reg open: %d", (int)lr);
    BootLog(b);
    if (lr == ERROR_SUCCESS) {
        DWORD diskCount = 0;
        DWORD size = sizeof(diskCount);
        LONG qr = RegQueryValueExA(hk, "Count", NULL, NULL, (LPBYTE)&diskCount, &size);
        sprintf(b, "[D] reg count: %lu", (unsigned long)diskCount);
        BootLog(b);
        if (qr == ERROR_SUCCESS && diskCount > 0) {
            int i;
            for (i = 0; i < (int)diskCount && count < maxCount; i++) {
                char idx[16];
                char path[256];
                DWORD pathSize = sizeof(path);
                int num;
                int qr2;
                sprintf(idx, "%d", i);
                if (RegQueryValueExA(hk, idx, NULL, NULL, (LPBYTE)path, &pathSize)
                        != ERROR_SUCCESS)
                    continue;                     /* 该项不存在，跳过 */
                num = parse_disk_number(path);
                if (num < 0) continue;            /* 路径格式异常，跳过 */
                /* 去重：同一盘号只保留第一次。disk\Enum 可能残留已拔出设备的
                 * "幽灵"项（如 USBSTOR 项末尾实例号 "&0" 被解析成盘号 0，
                 * 与真实盘重叠），重复盘号会导致 UI 重复行 / 清理时重复
                 * select disk N，这里按盘号跳过后续重复项 */
                if (is_number_seen(seen, seenCount, num)) {
                    sprintf(b, "[D] reg item %d: %s num=%d DUP skipped", i, path, num);
                    BootLog(b);
                    continue;
                }
                qr2 = query_one_disk(out + count, num);
                if (qr2) count++;
                if (seenCount < 64) seen[seenCount++] = num;
            }
        }
        RegCloseKey(hk);
        /* 注意：注册表有结果也不提前 return。RAID 卷（ps3stor 驱动暴露的 VD）
         * 挂在厂商驱动设备枚举下，不一定出现在 disk\Enum；若这里提前返回，
         * 后面的 PhysicalDrive 探测永远不会执行，RAID 卷就被漏掉。 */
    }

    /* 信息源 2：无条件探测 PhysicalDrive0..31（diskpart 枚举磁盘的同一接口）。
     * 这是主保障：只要 CreateFileA("\\.\PhysicalDriveN") 能打开（diskpart 能看到
     * 即能打开），RAID 卷必然被枚举到。与注册表结果按盘号合并去重。 */
    {
        int n;
        sprintf(b, "[D] probe PhysicalDrive0..31 (merge)");
        BootLog(b);
        for (n = 0; n < 32 && count < maxCount; n++) {
            int qr2;
            if (is_number_seen(seen, seenCount, n)) continue;  /* 与注册表项盘号重复则跳过 */
            qr2 = query_one_disk(out + count, n);
            if (qr2) count++;
            if (seenCount < 64) seen[seenCount++] = n;
            sprintf(b, "[D] probe %d: qr=%d", n, qr2);
            BootLog(b);
        }
    }
    sprintf(b, "[D] result: %d disks (merged)", count);
    BootLog(b);
    if (count > 0) return count;
    sprintf(b, "[D] result: -1 disks");
    BootLog(b);
    return -1;
}
