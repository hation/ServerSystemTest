#ifndef FIRPE_DISKS_H
#define FIRPE_DISKS_H

/*
 * disks.h - 磁盘枚举模块公共头
 * 纯 Win32 API（注册表 + DeviceIoControl），WinPE 兼容，无 WMI 依赖。
 */

typedef struct {
    int    Number;          /* 盘号 */
    char   Model[128];      /* 型号（ASCII，如 "Samsung SSD 970 EVO"） */
    char   Bus[24];         /* 总线文本（ASCII："USB"/"SATA"/"SCSI"/"NVMe"/"Unknown"） */
    long long SizeGB;       /* 总容量 GB（向下取整） */
    long long FreeGB;       /* 剩余 GB；-1 表示未知 */
    int    IsExcluded;      /* 1=排除 */
    int    Online;          /* 1=online 0=offline -1=unknown（diskpart list disk
                               解析，由 PopulateDiskList 填充；默认 -1） */
    char   Status[64];      /* 状态文本（ASCII，如上） */
} DiskInfo;

/* 枚举物理磁盘，结果写入 out（最多 maxCount 个）；返回数量；<0 表示失败 */
int EnumerateDisks(DiskInfo* out, int maxCount);

#endif /* FIRPE_DISKS_H */
