namespace FirpeCleaner.Core;

/// <summary>磁盘行模型：GUI 列表一行对应一块物理盘（枚举结果含排除标记，GUI 不勾选排除盘）。</summary>
public class DiskInfo
{
    /// <summary>盘号（对应 PhysicalDriveN / diskpart Disk N）。</summary>
    public int Number { get; init; }

    /// <summary>设备路径（<c>\\.\PhysicalDriveN</c>）。</summary>
    public string Device { get; init; } = "";

    /// <summary>序列号（WMI 无值或 diskpart 回退时为空串）。</summary>
    public string Sn { get; init; } = "";

    /// <summary>型号（如 ST8000NM000A / SAMSUNG MZQL21T9HCJR）。</summary>
    public string Model { get; init; } = "";

    /// <summary>总容量（GB，Round(Size/1GB)，1GB=1024^3）。</summary>
    public long SizeGB { get; init; }

    /// <summary>剩余容量（GB，Win32_DiskPartition+Win32_LogicalDisk 按盘归并）；null=拿不到（GUI 显示"—"）。</summary>
    public long? FreeGB { get; init; }

    /// <summary>总线类型（InterfaceType：USB/SCSI/SATA/NVMe/IDE…；diskpart 回退取自 detail disk 的 Type）。</summary>
    public string Bus { get; set; } = "";

    /// <summary>介质类型（MediaType：Fixed Hard Disk / Removable / CD/DVD…）。</summary>
    public string Media { get; init; } = "";

    /// <summary>是否被排除（USB/CD/系统盘/&lt;1GB；排除盘仍列出但 GUI 不勾选）。</summary>
    public bool IsExcluded { get; set; }

    /// <summary>排除原因（未排除时为空串）。</summary>
    public string ExcludeReason { get; set; } = "";

    /// <summary>是否为机械硬盘（Media=HDD 或 Bus=SAS，用于后续 GUI 类型标注）。</summary>
    public bool IsHdd { get; init; }

    /// <summary>是否为启动盘（diskpart 回退时 detail disk 的 "Boot Disk : Yes" 标记；WMI 主路径不设）。</summary>
    internal bool IsBoot { get; set; }
}
