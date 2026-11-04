param([switch]$KeepTasks)

# 卸载开机自动解锁，恢复成普通电脑的状态。
# 做的事：删掉四个计划任务（含桌面图标修复）；如果显卡处于禁用状态就启用回来。
# 不会做的事：不改注册表其它地方、不删日志、不碰 NVIDIA 驱动。

$ErrorActionPreference = 'Continue'

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
	$argLine = '-NoProfile -ExecutionPolicy Bypass -File "' + $PSCommandPath + '"'
	Start-Process -FilePath 'powershell.exe' -ArgumentList $argLine -Verb RunAs
	return
}

function Say([string]$m) { Write-Host $m }

if (-not $KeepTasks) {
	foreach ($t in 'GpuUnlockBoot', 'GpuUnlockOff', 'GpuUnlockBootRescue', 'GpuUnlockDeskFix') {
		$task = Get-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue
		if (-not $task) { Say ('[ -- ] ' + $t + '  本来就没有'); continue }
		try {
			Unregister-ScheduledTask -TaskName $t -Confirm:$false -ErrorAction Stop
			Say ('[ OK ] ' + $t + '  已删除')
		} catch {
			Say ('[ !! ] ' + $t + '  删除失败：' + $_.Exception.Message)
		}
	}
} else {
	foreach ($t in 'GpuUnlockBoot', 'GpuUnlockOff', 'GpuUnlockBootRescue', 'GpuUnlockDeskFix') {
		$r = & schtasks.exe /change /tn $t /disable 2>&1
		Say ('[ -- ] ' + $t + '  ' + (($r -join ' ').Trim()))
	}
}

$g = Get-PnpDevice -Class Display -ErrorAction SilentlyContinue | Where-Object { $_.InstanceId -like 'PCI\*' } | Select-Object -First 1
if ($g) {
	Say ('显卡状态：' + $g.Status)
	if ($g.Status -ne 'OK') {
		try {
			Enable-PnpDevice -InstanceId $g.InstanceId -Confirm:$false -ErrorAction Stop
			Say '[ OK ] 已发送启用命令，稍等几秒显示会回来'
		} catch {
			Say ('[ !! ] 启用失败：' + $_.Exception.Message)
			Say '       手动：设备管理器 → 显示适配器 → 右键报错的卡 → 启用设备'
		}
	} else {
		Say '[ -- ] 显卡本来就是启用的，不用动'
	}
}

Say ''
Say '已恢复原样：开机不再自动解锁。'
Say '（当前这一次运行的解锁值在下次重启后失效。）'
