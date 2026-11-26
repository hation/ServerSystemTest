using System.Runtime.Versioning;
using FirpeCleaner.Core;

namespace FirpeCleaner.Tests;

[SupportedOSPlatform("windows")]
public class DiskEnumeratorTests
{
    [Fact]
    public void Filter_ExcludesUsbAndCdAndSmall()
    {
        var disks = new List<DiskInfo>
        {
            new() { Number = 0, Bus = "SATA", Media = "Fixed hard disk media", SizeGB = 500, Model = "SATA-500G" },
            new() { Number = 1, Bus = "USB", Media = "Removable media", SizeGB = 28, Model = "USB-Flash" },
            new() { Number = 2, Bus = "SCSI", Media = "DVD/CD-ROM", SizeGB = 0, Model = "CD-DVD" },
            new() { Number = 3, Bus = "IDE", Media = "Fixed hard disk media", SizeGB = 0, Model = "Small-0G" },
            new() { Number = 4, Bus = "SAS", Media = "Fixed hard disk media", SizeGB = 900, Model = "SAS-900G" },
        };

        DiskEnumerator.Filter(disks);

        // SATA 固定盘保留
        Assert.False(disks[0].IsExcluded);
        Assert.Equal("", disks[0].ExcludeReason);
        // USB 排除
        Assert.True(disks[1].IsExcluded);
        Assert.Contains("USB", disks[1].ExcludeReason);
        // CD/DVD 介质排除
        Assert.True(disks[2].IsExcluded);
        Assert.Contains("CD", disks[2].ExcludeReason);
        // 容量 <1GB 排除
        Assert.True(disks[3].IsExcluded);
        Assert.Contains("1GB", disks[3].ExcludeReason);
        // SAS 大容量固定盘保留
        Assert.False(disks[4].IsExcluded);
    }

    [Fact]
    public void Filter_ExcludesBootDiskByIsBoot()
    {
        var disks = new List<DiskInfo>
        {
            new() { Number = 0, Bus = "SATA", Media = "Fixed hard disk media", SizeGB = 500, IsBoot = true },
            new() { Number = 1, Bus = "SATA", Media = "Fixed hard disk media", SizeGB = 500 },
        };

        DiskEnumerator.Filter(disks);

        // 系统盘（启动盘）排除，且优先级高于普通容量规则
        Assert.True(disks[0].IsExcluded);
        Assert.Contains("系统盘", disks[0].ExcludeReason);
        Assert.False(disks[1].IsExcluded);
    }

    [Fact]
    public void Filter_UsbMatchIsCaseInsensitiveContains()
    {
        // UAS/大小写变体：InterfaceType 可能为 "Usb"、含 "USB" 前缀等形式，须不区分大小写包含匹配
        var disks = new List<DiskInfo>
        {
            new() { Number = 0, Bus = "Usb", Media = "Fixed hard disk media", SizeGB = 500 },
            new() { Number = 1, Bus = "SCSI", Media = "Fixed hard disk media", SizeGB = 500 },
        };

        DiskEnumerator.Filter(disks);

        Assert.True(disks[0].IsExcluded);
        Assert.Contains("USB", disks[0].ExcludeReason);
        Assert.False(disks[1].IsExcluded);
    }

    [Fact]
    public void Filter_UnknownSizeMarksUnknownNotUnder1Gb()
    {
        var disks = new List<DiskInfo>
        {
            new() { Number = 0, Bus = "SATA", Media = "Fixed hard disk media", SizeGB = 0, SizeUnknown = true },
            new() { Number = 1, Bus = "SATA", Media = "Fixed hard disk media", SizeGB = 0 },
        };

        DiskEnumerator.Filter(disks);

        // Size 未知：标注"容量未知"而非误标 <1GB
        Assert.True(disks[0].IsExcluded);
        Assert.Contains("未知", disks[0].ExcludeReason);
        Assert.DoesNotContain("1GB", disks[0].ExcludeReason);
        // 确知 <1GB 仍按容量排除
        Assert.True(disks[1].IsExcluded);
        Assert.Contains("1GB", disks[1].ExcludeReason);
    }

    [Fact]
    public void ParseDiskpartOutput_ExtractsNumbers()
    {
        // 混合英文/中文 list disk + select/detail 示例（中文环境 diskpart 输出本地化，两者都要能解析）
        const string sample = """
            Microsoft DiskPart 版本 10.0.22621.1

            list disk

              Disk ###  Status         Size     Free     Dyn  Gpt
              --------  -------------  -------  -------  ---  ---
              Disk 0    Online          476 GB   372 GB        *
              Disk 1    No Media        0 B      0 B
              磁盘 2    联机    894 GB  894 GB       *

            select disk 0

            磁盘 0 现在是所选磁盘。

            detail disk

              磁盘 0
              类型   : SATA
              状态 : 联机
              Boot Disk  : Yes

            select disk 2

            磁盘 2 现在是所选磁盘。

            detail disk

              磁盘 2
              Type   : SAS
              Boot Disk  : No
            """;

        var disks = DiskEnumerator.ParseDiskpartOutput(sample);

        Assert.Equal(3, disks.Count);
        Assert.Equal(0, disks[0].Number);
        Assert.Equal(476, disks[0].SizeGB);
        Assert.Equal(@"\\.\PhysicalDrive0", disks[0].Device);
        // detail disk 的 Type 回填 Bus（英文/中文行均可）
        Assert.Equal("SATA", disks[0].Bus);
        Assert.Equal(1, disks[1].Number);
        Assert.Equal(0, disks[1].SizeGB);
        Assert.Equal(2, disks[2].Number);
        Assert.Equal(894, disks[2].SizeGB);
        Assert.Equal("SAS", disks[2].Bus);
        // 启动标记：盘 0 "Boot Disk : Yes" 置位，盘 2 "No" 不置位
        Assert.True(disks[0].IsBoot);
        Assert.False(disks[2].IsBoot);
    }

    [Fact]
    public void ParseDiskpartOutput_ChineseRealisticWithVolumeTable_NoDuplicateNumbers()
    {
        // 贴近真实的中文 diskpart 输出：detail 段含卷表段（"卷 0 … 476 GB"/"卷 1 … 550 MB" 等含"数字+单位"行）。
        // 旧版 DiskRowRegex 中 \s 可跨行 + 惰性量词，会从 detail 段头行"磁盘 0"跨行误匹配到卷行容量
        // → 产生重复盘号 → ToDictionary 抛异常（WinPE 无 WMI 时 diskpart 回退路径必崩）。此样本即回归防线。
        const string sample = """
            Microsoft DiskPart 版本 10.0.22621.1

            list disk

              磁盘 ###  状态    大小  可用  Dyn  Gpt
              --------  ------  -----  -----  ---  ---
              磁盘 0    联机    476 GB  372 GB       *
              磁盘 1    无介质  0 B    0 B
              磁盘 2    联机    894 GB  894 GB       *

            select disk 0

            磁盘 0 现在是所选磁盘。

            detail disk

              磁盘 0
              类型   : SATA
              状态   : 联机
              路径   : 0
              目标   : 0
              LUN ID : 0
              位置路径 : ACPI(_SB_)#ACPI(PCI0)#ACPI(SCK0)#ACPI(PCI0)#ACPI(PRC0)
              当前只读状态: 否
              只读: 否
              启动磁盘: 是
              启动文件: C:\Windows
              杂项: 是
              没有

              卷 0  C  NTFS  分区  476 GB  正常
              卷 1       恢复    550 MB  正常

            select disk 2

            磁盘 2 现在是所选磁盘。

            detail disk

              磁盘 2
              类型   : SAS
              状态   : 联机
              路径   : 0
              目标   : 0
              LUN ID : 0
              位置路径 : PCIROOT(0)#PCI(0x17)
              当前只读状态: 否
              只读: 否
              启动磁盘: 否
              没有

              卷 0  C  NTFS  分区  894 GB  正常
            """;

        var disks = DiskEnumerator.ParseDiskpartOutput(sample);

        // 无重复盘号（旧版跨行误匹配卷表会产生重复盘号 → 字典构建崩溃）
        Assert.Equal(3, disks.Count);
        Assert.Equal(3, disks.Select(d => d.Number).Distinct().Count());
        // list disk 行解析正确，卷表段不干扰（盘 0 容量仍为 476 GB 而非卷行的 550 MB）
        Assert.Equal(0, disks[0].Number);
        Assert.Equal(476, disks[0].SizeGB);
        Assert.Equal(1, disks[1].Number);
        Assert.Equal(0, disks[1].SizeGB);
        Assert.Equal(2, disks[2].Number);
        Assert.Equal(894, disks[2].SizeGB);
        // detail 段回填 Bus/IsBoot（中文"类型/启动磁盘"行）
        Assert.Equal("SATA", disks[0].Bus);
        Assert.True(disks[0].IsBoot);
        Assert.Equal("SAS", disks[2].Bus);
        Assert.False(disks[2].IsBoot);
    }

    // ---------------- WMI 系统盘判定（Win32_DiskPartition.BootPartition） ----------------

    [Fact]
    public void FindBootDiskIndex_ReturnsDiskIndexOfBootPartition()
    {
        // 构造假分区数据：仅盘 1 的分区 BootPartition=True → 系统盘盘号应为 1（EnumerateByWmi 据此置 IsBoot）
        var partitions = new (int DiskIndex, bool? BootPartition)[]
        {
            (0, false),
            (1, true),
            (2, null), // BootPartition 无值（属性未提供）按非启动分区跳过
        };

        Assert.Equal(1, DiskEnumerator.FindBootDiskIndex(partitions));
    }

    [Fact]
    public void FindBootDiskIndex_NoBootPartition_ReturnsMinusOne()
    {
        // 无任何 BootPartition=True 分区（如纯 PE 环境）→ 返回 -1，不标记任何盘为系统盘
        var partitions = new (int DiskIndex, bool? BootPartition)[]
        {
            (0, false),
            (2, null),
            (3, false),
        };

        Assert.Equal(-1, DiskEnumerator.FindBootDiskIndex(partitions));
    }

    [Fact]
    public void FindBootDiskIndex_MultipleBootPartitions_TakesFirst()
    {
        // 多启动分区（双系统/双启动盘）取首个 BootPartition=True，与 diskpart 首个 "Boot Disk: Yes" 语义一致
        var partitions = new (int DiskIndex, bool? BootPartition)[]
        {
            (0, true),
            (1, true),
        };

        Assert.Equal(0, DiskEnumerator.FindBootDiskIndex(partitions));
    }
}
