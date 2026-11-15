# ============================================================================
# lib_common.ps1 — 服务器整机测试通用函数库骨架（PowerShell 5.1 兼容）
# 定位：从 disk-tests（硬盘）/ memory-tests（内存）两项目提取的"工程基因"通用版，
#       已去业务化：只保留通用可复用函数，业务函数仅留签名+注释，由新项目
#       按 02/05 号文档（批量检测 SOP / 使用手册）实现。
# 用法：在业务脚本 param 之后 dot-source 加载：. (Join-Path $PSScriptRoot "lib_common.ps1")
#
# 通用函数清单：
#   Get-Config          读 conf/app.conf（键值注释格式，跳过 # 与 [ 行，支持行内 # 注释）
#   Write-Log           写 logs\<project>.log + 控制台（UTF-8）
#   Test-IsAdmin        是否管理员
#   Get-StageDone / Set-StageDone   .done 阶段标记（断点续跑）
#   Wait-Slot           并发槽位等待（[ref] 参数，进程集合）
#   Write-Event         向 stdout 输出一行 JSON 事件（type∈stage/entity/progress/error/done）
#   Get-AppVersion      读项目根 VERSION 文件，读不到返回 "dev"（版本单一来源，勿硬编码）
#   ConvertTo-CsvField  CSV 字段转义（含逗号/引号/换行加引号并双写引号）
#   Get-EntityHash01    实体唯一键 31 哈希 → [0,1)，同 key 结果稳定（确定性抽样深测用）
#   Write-CmdLog        指令记录 results\cmdlog\commands-<日期>.csv（密码打码 ***，UTF-8）
#
# 业务函数（占位签名，需按 02/05 号文档实现）：
#   Get-TestTargets / Confirm-Targets / Test-TargetClear / New-TaskChecklist
# ============================================================================

# 项目根：本文件所在目录的父目录（本文件放 bin\ 或 scripts\ 下即自动指向项目根）
$script:ProjectRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
# 项目名：用于日志/批次等命名（占位，可改）
$script:ProjectName = "server-tests"

# 工具版本：dev（构建时由 build.ps1 从 VERSION 注入；日常开发保持 dev，勿手改）

# 读取 conf/app.conf，返回键值对 Hashtable
# 行为：跳过空行 / # 注释行 / [ 节标题行；支持行内 # 注释（值取 # 前部分并 Trim）；非法键跳过不报错
function Get-Config {
    $conf = @{}
    $path = Join-Path $script:ProjectRoot "conf\app.conf"
    if (-not (Test-Path $path)) { return $conf }
    foreach ($line in Get-Content $path) {
        $line = $line.Trim()
        if ($line -eq "" -or $line.StartsWith("#") -or $line.StartsWith("[")) { continue }
        if ($line -match "^([A-Za-z0-9_]+)=(.*)$") {
            $conf[$matches[1]] = $matches[2].Trim().Split("#")[0].Trim()
        }
    }
    return $conf
}

# 日志：写 logs\<project>.log + 控制台（UTF-8）
function Write-Log {
    param([string]$Msg, [string]$Level = "INFO")
    $logDir = Join-Path $script:ProjectRoot "logs"
    if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Force $logDir | Out-Null }
    $line = "[{0}][{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Level, $Msg
    Add-Content -Path (Join-Path $logDir ("{0}.log" -f $script:ProjectName)) -Value $line -Encoding UTF8
    Write-Host $line
}

# 是否管理员权限（磁盘级/系统级操作前检查）
function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# .done 阶段标记读取（断点续跑：已完成的阶段跳过）
function Get-StageDone {
    param([string]$Dir, [string]$Stage)
    return (Test-Path (Join-Path $Dir ".$Stage.done"))
}

# .done 阶段标记写入
function Set-StageDone {
    param([string]$Dir, [string]$Stage)
    New-Item -ItemType Directory -Force $Dir | Out-Null
    New-Item -ItemType File -Force (Join-Path $Dir ".$Stage.done") | Out-Null
}

# 并发槽位等待：$Running 是进程集合的引用（[ref]），存活进程数达到 $Max 时轮询等待
function Wait-Slot {
    param([ref]$Running, [int]$Max)
    $alive = @($Running.Value | Where-Object { -not $_.HasExited })
    while ($alive.Count -ge $Max) {
        Start-Sleep -Seconds 5
        $alive = @($Running.Value | Where-Object { -not $_.HasExited })
    }
    $Running.Value = $alive
}

# 事件流：向 stdout 输出一行 JSON {"type":...,"data":{...}}，供外部工具/编排机消费
# type 取值约定：stage（阶段切换）/ entity（实体事件）/ progress（进度）/ error（错误）/ done（完成）
function Write-Event {
    param([string]$Type, [hashtable]$Data = @{})
    [PSCustomObject]@{ type = $Type; data = $Data } | ConvertTo-Json -Compress
}

# 应用版本：读项目根 VERSION（trim），读不到/为空返回 "dev"（版本单一来源，勿硬编码）
$script:AppVersion = $null
function Get-AppVersion {
    if ($null -ne $script:AppVersion) { return $script:AppVersion }
    $vFile = Join-Path $script:ProjectRoot "VERSION"
    if (Test-Path $vFile) {
        $v = (Get-Content -Path $vFile -Raw).Trim()
        if ($v -ne "") { $script:AppVersion = $v; return $v }
    }
    return "dev"
}

# CSV 字段转义：值含逗号/引号/换行时加引号并双写内部引号（结果 CSV 共用）
function ConvertTo-CsvField {
    param([object]$Value)
    $s = if ($null -eq $Value) { "" } else { [string]$Value }
    if ($s -match '[",\r\n]') { $s = '"' + ($s -replace '"', '""') + '"' }
    return $s
}

# 确定性实体唯一键哈希 → [0,1)：31 哈希算法（同 key 结果稳定，不依赖 .NET 随机哈希），
# 用于按实体抽样深测（如抽中比例<1 时决定该实体是否跑深度测试）
function Get-EntityHash01 {
    param([string]$Key)
    $h = 0
    foreach ($ch in $Key.ToCharArray()) {
        $h = ($h * 31 + [int]$ch) % 2147483647
    }
    return (($h % 100000) / 100000.0)
}

# 指令记录（cmdlog）：把每次脚本调用记入 <项目根>\results\cmdlog\commands-YYYY-MM-DD.csv
# 常开、CSV、按日期滚动；敏感参数（密码类 -Pass/-Password/-Pwd/-BmcPass/-P）自动打码为 ***
function Write-CmdLog {
    param(
        [string]$Script,
        [string]$CmdArgs = '',
        [string]$State = 'Start',
        [string]$Result = '',
        [int]$ExitCode = 0,
        [double]$DurationSec = 0
    )
    $masked = $CmdArgs
    foreach ($re in @(
        '(?i)(-(?:Pass|Password|Pwd|BmcPass|P)\s+)(?:''[^'']*(?:''''[^'']*)*''|\S+)',
        '(?i)(-(?:Pass|Password|Pwd|BmcPass|P)=)(\S+)'
    )) {
        $masked = $masked -replace $re, ('${1}' + '***')
    }
    $row = [PSCustomObject]@{
        Timestamp   = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        Machine     = $env:COMPUTERNAME
        Dir         = (Get-Location).Path
        Script      = $Script
        Args        = $masked
        State       = $State
        Result      = $Result
        ExitCode    = $ExitCode
        DurationSec = $DurationSec
    }
    $logDir = Join-Path $script:ProjectRoot 'results\cmdlog'
    if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
    $file = Join-Path $logDir ("commands-{0:yyyy-MM-dd}.csv" -f (Get-Date))
    if (-not (Test-Path $file)) {
        $row | Export-Csv -Path $file -NoTypeInformation -Encoding UTF8
    } else {
        $row | ConvertTo-Csv -NoTypeInformation | Select-Object -Skip 1 | Add-Content -Path $file -Encoding UTF8
    }
}

# ==================== 业务函数（占位骨架：需按 02/05 号文档实现） ====================

# 识别被测实体：枚举本机被测目标（如整机/硬盘/内存），排除系统/管理设备，返回目标列表
# 参考原 Get-TestDisks（disk-tests）/ Get-MemoryInventory（memory-tests）；
# 新项目按 02/05 号文档定义识别规则与返回结构（须含唯一键字段，供 db 入库与抽样）
function Get-TestTargets {
    param()   # 业务签名待定：新项目定义
    throw "Get-TestTargets 为业务占位函数，请按 02/05 号文档实现"
}

# 打印目标清单并要求二次确认：-Yes 跳过确认直接返回 $true；-DryRun 只预览不执行
# 返回 bool 是否继续；参考原 Confirm-Targets（memory-tests），新项目补充清单字段
function Confirm-Targets {
    param(
        [array]$Targets,
        [switch]$Yes,
        [switch]$DryRun
    )
    throw "Confirm-Targets 为业务占位函数，请按 02/05 号文档实现"
}

# 被测目标是否满足测试前置条件（如已清空/无分区/无残留，参考原 Test-DiskClear），返回 bool
# 新项目按 02/05 号文档定义检查项；不满足时由调用方拦截并提示人工处理
function Test-TargetClear {
    param()   # 业务签名待定：新项目定义（目标唯一键）
    throw "Test-TargetClear 为业务占位函数，请按 02/05 号文档实现"
}

# 生成任务清单：测试开始前生成计划，测试结束后填结果（参考原 New-TaskChecklist 系列）
# 新项目按 02/05 号文档定义环节项与更新机制（Update-* 配套函数一并实现）
function New-TaskChecklist {
    param()   # 业务签名待定：新项目定义（批次目录/批次号/目标清单等）
    throw "New-TaskChecklist 为业务占位函数，请按 02/05 号文档实现"
}
