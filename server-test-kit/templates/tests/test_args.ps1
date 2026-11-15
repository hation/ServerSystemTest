# test_args.ps1 —— 参数构建断言骨架
# 运行：powershell -NoProfile -ExecutionPolicy Bypass -File test_args.ps1
# 通过输出 PASS 行；任一条失败输出 FAIL 行并以非零退出码结束。
# 背景：原项目 JoinArgs 教训——参数含空格/逗号/元字符时必须正确引用，
# 否则命令拼接后参数被拆散或被注入，导致采集/判定命令行为错误。

$ErrorActionPreference = 'Stop'
$script:failCount = 0

function Assert-Equal {
    param([string]$Name, [string]$Expected, [string]$Actual)
    if ($Expected -eq $Actual) {
        Write-Host "PASS  $Name"
    } else {
        Write-Host "FAIL  $Name"
        Write-Host "      期望: [$Expected]"
        Write-Host "      实际: [$Actual]"
        $script:failCount++
    }
}

# JoinArgs —— 把参数数组拼成命令行字符串。
# 含空格/逗号/元字符（" & | < > ^）的参数用双引号包裹，内部双引号转义为 \"。
# （骨架示例：真实实现见 lib_common.ps1，另按调用目标 shell 处理元字符前缀）
function JoinArgs {
    param([string[]]$ArgList)
    $parts = foreach ($a in $ArgList) {
        if ($a -match '[\s,"&|<>^]') {
            '"' + ($a -replace '"', '\"') + '"'
        } else {
            $a
        }
    }
    return ($parts -join ' ')
}

Write-Host "== 参数构建断言 =="

# 普通参数不引用
Assert-Equal '普通参数不引用' '--number 1' (JoinArgs @('--number', '1'))

# 含空格参数必须引用
Assert-Equal '含空格参数引用' '--out "C:\temp\process out"' (JoinArgs @('--out', 'C:\temp\process out'))

# 含逗号参数必须引用（原项目教训：--backfill "52,55,60-62" 这类参数）
Assert-Equal '含逗号参数引用' '--config "a,b"' (JoinArgs @('--config', 'a,b'))

# 含元字符参数必须引用（& | < > ^ 会被 shell 解释）
Assert-Equal '含元字符参数引用' '--note "x&y"' (JoinArgs @('--note', 'x&y'))

# 内部双引号必须转义
Assert-Equal '内部双引号转义' '--note "say \"hi\""' (JoinArgs @('--note', 'say "hi"'))

# 多参数混合拼接
Assert-Equal '多参数混合' '--collect "dir a" --number 2 --date 20261113' (JoinArgs @('--collect', 'dir a', '--number', '2', '--date', '20261113'))

# 空参数列表
Assert-Equal '空参数列表' '' (JoinArgs @())

if ($script:failCount -gt 0) {
    Write-Host "结果: $($script:failCount) 条失败"
    exit 1
} else {
    Write-Host "结果: 全部通过"
    exit 0
}
