# FuckACE - Powershell Version
Fuck Tencent ACE

监控 SGuard64.exe、SGuardSvc64.exe 等进程，并在检测到它们启动后自动：

将进程优先级调整为 Idle（最低）

将 CPU 强制绑定到 指定核心（默认最后一个核心）

仅第一次设置，之后不重复修改，仅进行状态监控

```
Set-ExecutionPolicy RemoteSigned
.\fuckace.ps1
```

参数：
```
$TargetProcesses = @('sguard', 'sguard64')  # 要监控的进程名
$IntervalSeconds = 5                        # 检查间隔（秒）
$CoreSelection = "Last"                     # First / Last / 或数字索引
$ShowAlreadyOkMessage = $false              # 是否显示已处于目标状态的提示
```
