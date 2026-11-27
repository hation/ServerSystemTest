#ifndef FIRPE_DRIVER_H
#define FIRPE_DRIVER_H

/*
 * driver.h - 驱动自愈模块公共头（Linkdata PS3Stor RAID 卡）
 * 场景：FirPE 不含目标 RAID 卡驱动（如 Linkdata 2230-18i，IOC2250 芯片，
 * PCI VEN_1ff2&DEV_20a2）导致 0 盘可清时，自动尝试注入官方驱动
 * （ps3stor.inf/.sys，WHQL 签名但证书已过期），签名失败时逐级降级绕过。
 * 只匹配 Linkdata 硬件（VEN_1ff2），绝不误装。纯 Win32 API，WinPE 兼容。
 */

#include <windows.h>

/* 驱动自愈结果 */
typedef struct {
    int  Attempted;       /* 1=已尝试注入 */
    int  Loaded;          /* 1=驱动已成功加载（盘应立即可见） */
    int  InjectedToFirpe; /* 1=已注入 FirPE\Drivers（需重启生效） */
    int  TestsigningSet;  /* 1=已改 U 盘 BCD 开测试签名（需重启生效） */
    char Detail[512];     /* 每步结果摘要（ASCII），用于日志/UI */
    char InfPath[MAX_PATH]; /* 实际找到/使用的 inf 路径；未找到则为空串 */
} DriverSelfHealResult;

/* 在给定目录下找 Linkdata PS3Stor 驱动 inf（不区分大小写，ps3stor.inf）
 * dir 传 NULL 时自动探测 exe 同目录的 "drivers" 子目录（其次 "tools\Win2022"）。
 * 找到返回 inf 完整路径（内部静态缓冲），否则返回 NULL。 */
const char* FindPs3StorInf(const char* dir);

/* 探测/创建 FirPE U 盘上的子目录 sub（如 "Drivers"/"Log"）：X:\FirPE\<sub>。
 * 通用盘符扫描：目录不存在则自动创建；先 DRIVE_REMOVABLE（优先 U 盘）
 * 再 DRIVE_FIXED（Ventoy 常把 U 盘识别为固定盘），跳过 RAMDISK/CDROM 等。
 * 返回 1 成功（out 收目录完整路径），0 全部失败。 */
int FindFirpeSubDir(const char* sub, char* out, int outLen);

/* 探测/创建 FirPE U 盘上的 Drivers 目录（X:\FirPE\Drivers）：
 * 智能创建模式：目录不存在也主动创建（Ventoy 盘无 FirPE 文件夹）。
 * 两轮遍历盘符 A..Z：先 DRIVE_REMOVABLE（优先 U 盘）再 DRIVE_FIXED，
 * 跳过 RAMDISK（FirPE 桌面 RAM 盘，重启丢失）/ CDROM 等。
 * 返回 1 找到/创建成功（out 收到目录完整路径），0 全部失败。 */
int FindFirpeDriversDir(char* out, int outLen);

/* 把 inf 同目录的 ps3stor.inf/.sys/.cat 复制到 dstDir（.cat 缺失不影响）。
 * 返回 1=至少 inf+sys 复制成功。 */
int CopyDriverToDir(const char* infPath, const char* dstDir);

/* 探测 FirPE U 盘上的 BCD：X:\EFI\Microsoft\Boot\BCD 或 X:\boot\BCD。
 * 找到返回 1（out 收到 BCD 完整路径），否则返回 0。 */
int FindFirpeBcd(char* out, int outLen);

/* 全流程：找 inf → pnputil 安装 → 失败逐级降级（L2→L3→L4→L5→L6）。
 * 执行期间调用 AppendLog 记录每步。返回 DriverSelfHealResult。 */
DriverSelfHealResult SelfHealDriver(void);

/* 检测系统里是否已有 Linkdata 存储设备（PCI VEN_1ff2）。
 * 用 SetupAPI 枚举；TCC 无 setupapi.def 则回退：注册表
 * HKLM\SYSTEM\CurrentControlSet\Enum\PCI 下搜索含 "VEN_1ff2" 的子键名（遍历）。
 * 返回 1=存在 Linkdata 设备，0=不存在/未知。 */
int HasLinkdataDevice(void);

#endif /* FIRPE_DRIVER_H */
