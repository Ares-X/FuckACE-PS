#requires -version 5.1
<#
.SYNOPSIS
  监控并限制 sguard / sguard64 占用：设置为 Idle 优先级，并绑定到最后一个逻辑核心。

.DESCRIPTION
  周期性扫描指定进程：
    - 如果进程未按目标配置运行，则设置：
        * PriorityClass = Idle
        * ProcessorAffinity = 最后一个逻辑核心
    - 如果已经是目标配置，则只监控，不重复设置。

  建议以管理员权限运行。
#>

# ===================== 配置区域 =====================

# 监控的进程名（不带 .exe，大小写不敏感）
$TargetProcesses = @('SGuard64', 'SGuardSvc64')

# 检查间隔（秒）
$IntervalSeconds = 5

# 是否打印“已处于目标配置”的调试信息（默认关闭避免刷屏）
$ShowAlreadyConfiguredMessage = $false

# 绑定到哪个逻辑核心：
#   "Last"  = 最后一个逻辑核心（例如 8 核则为索引 7）
#   "First" = 第一个逻辑核心（索引 0）
#   也可以直接填具体核心索引（0-based，如 3 表示第 4 个核心）
$CoreSelection = "Last"

# =================== 配置结束 =======================

Write-Host "================ Watch-SGuard 启动 ================"
Write-Host ("启动时间：{0}" -f (Get-Date))
Write-Host ("监控进程：{0}" -f ($TargetProcesses -join ', '))
Write-Host ("检查间隔：{0} 秒" -f $IntervalSeconds)
Write-Host ""

# 计算目标核心掩码
$cpuCount = [Environment]::ProcessorCount
if ($cpuCount -lt 1) {
    Write-Error "无法获取 CPU 核心数量，退出。"
    exit 1
}

function Get-TargetCoreMask {
    param(
        [string]$Selection,
        [int]$CpuCount
    )

    switch -Regex ($Selection) {
        '^Last$' {
            $idx = $CpuCount - 1
        }
        '^First$' {
            $idx = 0
        }
        '^\d+$' {
            $idx = [int]$Selection
            if ($idx -lt 0 -or $idx -ge $CpuCount) {
                throw "指定核心索引 $idx 超出范围 [0, $($CpuCount-1)]"
            }
        }
        default {
            throw "无效的 CoreSelection：$Selection，可选 First / Last 或具体数字索引。"
        }
    }

    # 掩码 = 1 << index
    return (1 -shl $idx)
}

try {
    $TargetCoreMask = Get-TargetCoreMask -Selection $CoreSelection -CpuCount $cpuCount
} catch {
    Write-Error $_.Exception.Message
    exit 1
}

$TargetCoreMaskHex = ('0x{0:X}' -f $TargetCoreMask)
Write-Host ("检测到逻辑核心数：{0}，目标核心选择：{1}，掩码：{2}" -f $cpuCount, $CoreSelection, $TargetCoreMaskHex)
Write-Host "===================================================="
Write-Host "按 Ctrl + C 可停止脚本。"
Write-Host ""

# 进程状态表：用来记录已经配置过的 PID，避免重复设置
# 结构示例：
#   $ProcessState[pid] = @{
#       Name          = 'sguard'
#       LastAffinity  = 0x80
#       LastPriority  = 'Idle'
#       FirstSetTime  = [DateTime]
#   }
$ProcessState = @{}

# 获取目标优先级常量
$TargetPriority = [System.Diagnostics.ProcessPriorityClass]::Idle

while ($true) {
    try {
        # 当前所有需要监控的进程
        $procs = @()
        foreach ($name in $TargetProcesses) {
            $tmp = Get-Process -Name $name -ErrorAction SilentlyContinue
            if ($tmp) { $procs += $tmp }
        }

        # 当前存活 PID 集合，用于清理状态表中“已经退出”的进程
        $alivePids = [System.Collections.Generic.HashSet[int]]::new()

        foreach ($p in $procs) {
            if ($p.HasExited) { continue }

            $alivePids.Add($p.Id) | Out-Null

            $ProcId = [int]$p.Id
            $needChange = $false
            $reason = @()

            # --- 检查优先级 ---
            try {
                if ($p.PriorityClass -ne $TargetPriority) {
                    $needChange = $true
                    $reason += "Priority"
                }
            } catch {
                Write-Warning ("[{0}] 读取 {1} (PID {2}) 优先级失败：{3}" -f (Get-Date), $p.ProcessName, $p.Id, $_.Exception.Message)
                continue
            }

            # --- 检查 CPU 亲和性 ---
            try {
                # 有些系统可能暂时获取不到 ProcessorAffinity
                if ($p.ProcessorAffinity -ne $TargetCoreMask) {
                    $needChange = $true
                    $reason += "Affinity"
                }
            } catch {
                Write-Warning ("[{0}] 读取 {1} (PID {2}) 亲和性失败：{3}" -f (Get-Date), $p.ProcessName, $p.Id, $_.Exception.Message)
                continue
            }

            if ($needChange) {
                # 只有在不满足目标配置时才真正设置
                try {
                    $p.PriorityClass = $TargetPriority
                    $p.ProcessorAffinity = $TargetCoreMask

                    $ProcessState[$ProcId] = @{
                        Name         = $p.ProcessName
                        LastAffinity = $TargetCoreMask
                        LastPriority = $TargetPriority.ToString()
                        FirstSetTime = (Get-Date)
                    }

                    Write-Host ("[{0}] 已配置 {1} (PID {2}) -> Priority=Idle, Affinity={3}，原因：{4}" -f `
                        (Get-Date), $p.ProcessName, $p.Id, $TargetCoreMaskHex, ($reason -join '+'))
                } catch {
                    Write-Warning ("[{0}] 设置 {1} (PID {2}) 失败：{3}" -f (Get-Date), $p.ProcessName, $p.Id, $_.Exception.Message)
                }
            } else {
                # 已经是目标配置：只监控，不重复设置
                if ($ShowAlreadyConfiguredMessage) {
                    if ($ProcessState.ContainsKey($ProcId)) {
                        $firstSet = $ProcessState[$ProcId].FirstSetTime
                        Write-Host ("[{0}] {1} (PID {2}) 已处于目标配置（首次设置于 {3}）" -f `
                            (Get-Date), $p.ProcessName, $p.Id, $firstSet)
                    } else {
                        # 理论上首次循环可能就已经是 Idle+目标亲和，这里记录一下状态
                        $ProcessState[$ProcId] = @{
                            Name         = $p.ProcessName
                            LastAffinity = $TargetCoreMask
                            LastPriority = $TargetPriority.ToString()
                            FirstSetTime = (Get-Date)
                        }
                        Write-Host ("[{0}] {1} (PID {2}) 初次发现即已满足目标配置，记录为已配置。" -f `
                            (Get-Date), $p.ProcessName, $p.Id)
                    }
                } else {
                    # 静默监控：仅保证 ProcessState 里有一份记录即可
                    if (-not $ProcessState.ContainsKey($ProcId)) {
                        $ProcessState[$ProcId] = @{
                            Name         = $p.ProcessName
                            LastAffinity = $TargetCoreMask
                            LastPriority = $TargetPriority.ToString()
                            FirstSetTime = (Get-Date)
                        }
                    }
                }
            }
        }

        # 清理状态表中已经退出的进程
        if ($ProcessState.Count -gt 0) {
            $toRemove = @()
            foreach ($key in $ProcessState.Keys) {
                if (-not $alivePids.Contains($key)) {
                    $toRemove += $key
                }
            }

            foreach ($procid in $toRemove) {
                $info = $ProcessState[$procid]
                $ProcessState.Remove($procid) | Out-Null
                Write-Host ("[{0}] 检测到 {1} (PID {2}) 已退出，从状态表移除。" -f `
                    (Get-Date), $info.Name, $procid)
            }
        }

    } catch {
        Write-Warning ("[{0}] 主循环异常：{1}" -f (Get-Date), $_.Exception.Message)
    }

    Start-Sleep -Seconds $IntervalSeconds
}
