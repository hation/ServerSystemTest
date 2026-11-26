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
    }
}
