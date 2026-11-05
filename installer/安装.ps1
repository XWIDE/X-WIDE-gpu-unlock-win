param([switch]$CheckOnly, [string]$Root)

# 安装开机自动解锁（冷启动路线）
# 做的事：注册三个计划任务，让每次开机在驱动绑定前解锁显卡。
# 不做的事：不下载任何东西、不改 VBIOS、不碰 NVIDIA 驱动文件。

$ErrorActionPreference = 'Stop'
# 解锁程序可能在这些位置，按顺序找第一个能找到 gpu_unlock.exe 的：
#   -Root 指定 → 脚本同级 → 脚本下的 scripts\ → 上一级
$candidates = @()
if ($Root) { $candidates += $Root }
$candidates += $PSScriptRoot
$candidates += (Join-Path $PSScriptRoot 'scripts')
$candidates += (Split-Path $PSScriptRoot -Parent)
$root = $PSScriptRoot
foreach ($c in $candidates) {
	if ($c -and (Test-Path (Join-Path $c 'gpu_unlock.exe'))) { $root = $c; break }
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin -and -not $CheckOnly) {
	$argLine = '-NoProfile -ExecutionPolicy Bypass -File "' + $PSCommandPath + '"'
	Start-Process -FilePath 'powershell.exe' -ArgumentList $argLine -Verb RunAs
	return
}

$need = @(
	'gpu_unlock.exe',
	'gpuunlock.sys',
	'boot-unlock.ps1',
	'gpu-disable.ps1',
	'rescue-enable.ps1',
	'desk-fix.ps1'
)

function Line([string]$name, [bool]$ok, [string]$extra) {
	$tag = '[ -- ]'
	if ($ok) { $tag = '[ OK ]' }
	Write-Host ($tag + ' ' + $name + '  ' + $extra)
}

$fail = 0
Write-Host '=== 环境检查 ==='
foreach ($f in $need) {
	$p = Join-Path $root $f
	$ok = Test-Path $p
	if (-not $ok) { $fail++ }
	Line $f $ok $(if ($ok) { '' } else { '缺失' })
}

$assetDir = Get-ChildItem (Join-Path $root 'gpu-unlock') -Directory -ErrorAction SilentlyContinue | Select-Object -First 1
$okAsset = [bool]($assetDir -and (Get-ChildItem $assetDir.FullName -Filter '*.bin' | Where-Object { $_.Length -gt 1000 }))
if (-not $okAsset) { $fail++ }
Line '固件资产' $okAsset $(if ($assetDir) { $assetDir.Name + ' / ' + (@(Get-ChildItem $assetDir.FullName -Filter '*.bin').Count) + ' 个 bin' } else { '找不到 gpu-unlock 目录' })

# bcdedit 的输出是本地化的（中文系统显示"是"），且未提权时读不到。
$tsOut = (bcdedit.exe /enum '{current}' 2>&1 | Out-String)
$tsLine = ($tsOut -split "`r?`n" | Where-Object { $_ -match 'testsigning' } | Select-Object -First 1)
if (-not $tsLine) {
	Line '测试签名 testsigning' $false '读不到 BCD（请用管理员运行安装.ps1）；确认已跑过 enable-test-signing.ps1 并重启'
} else {
	$on = [bool]($tsLine -match '(?i)\b(Yes|On|是)\b')
	if (-not $on) { $fail++ }
	Line '测试签名 testsigning' $on $(if ($on) { '已开启' } else { '未开启：先跑同目录的 enable-test-signing.ps1 并重启' })
}

$sb = try { (Get-CimInstance -Namespace root\wmi -ClassName UEFI_SecureBootVariable -ErrorAction Stop) } catch { $null }
$okSb = $true
try {
	$sbOn = (Confirm-SecureBootUEFI -ErrorAction Stop)
	if ($sbOn) { $okSb = $false }
} catch { $okSb = $true }
if (-not $okSb) { $fail++ }
Line 'Secure Boot' $okSb $(if ($okSb) { '已关闭 或 无法查询' } else { '必须先在 BIOS 里关闭' })

$g = Get-PnpDevice -Class Display -ErrorAction SilentlyContinue | Where-Object { $_.InstanceId -like 'PCI\*' } | Select-Object -First 1
Line '显卡' ([bool]$g) $(if ($g) { $g.FriendlyName + ' / ' + $g.Status } else { '找不到 PCI 显示设备' })
if (-not $g) { $fail++ }

$gpu = Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | Select-Object -First 1
if ($gpu) { Write-Host ('       驱动版本 ' + $gpu.DriverVersion + '（本方案不要求特定版本）') }

Write-Host ''
Write-Host '=== 计划任务 ==='
$tasks = @(
	@{
		name = 'GpuUnlockBoot'
		desc = '开机在驱动绑定前解锁显卡（冷启动路径）'
		script = 'boot-unlock.ps1'
		trigger = '<BootTrigger><Enabled>true</Enabled></BootTrigger>'
	},
	@{
		name = 'GpuUnlockBootRescue'
		desc = '开机 5 分钟后兜底：显卡没启用就强行启用'
		script = 'rescue-enable.ps1'
		trigger = '<BootTrigger><Enabled>true</Enabled><Delay>PT5M</Delay></BootTrigger>'
	},
	@{
		name = 'GpuUnlockOff'
		desc = '关机时禁用显卡，让下次开机是冷态'
		script = 'gpu-disable.ps1'
		trigger = '<EventTrigger><Enabled>true</Enabled><Subscription>&lt;QueryList&gt;&lt;Query Id="0" Path="System"&gt;&lt;Select Path="System"&gt;*[System[EventID=1074]]&lt;/Select&gt;&lt;/Query&gt;&lt;/QueryList&gt;</Subscription></EventTrigger>'
	},
	@{
		name = 'GpuUnlockDeskFix'
		desc = '登录后跑一次：恢复桌面图标大小、图标层、被隐藏的图标，把跑到屏幕外的图标搬回可视区'
		script = 'desk-fix.ps1'
		args = '-Reflow -NoPause'
		timeLimit = 'PT5M'
		trigger = '<LogonTrigger><Enabled>true</Enabled><UserId>' + [Security.Principal.WindowsIdentity]::GetCurrent().User.Value + '</UserId><Delay>PT45S</Delay></LogonTrigger>'
		user = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
	}
)

foreach ($t in $tasks) {
	$scriptPath = Join-Path $root $t.script
	$runAs = 'S-1-5-18'
	if ($t.user) { $runAs = $t.user }
	$xml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo><Description>$($t.desc)</Description></RegistrationInfo>
  <Triggers>$($t.trigger)</Triggers>
  <Principals><Principal id="Author"><UserId>$runAs</UserId><RunLevel>HighestAvailable</RunLevel></Principal></Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>false</StartWhenAvailable>
    <ExecutionTimeLimit>$($(if ($t.timeLimit) { $t.timeLimit } else { 'PT5M' }))</ExecutionTimeLimit>
    <Enabled>true</Enabled>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>powershell.exe</Command>
      <Arguments>-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "$scriptPath" $($t.args)</Arguments>
    </Exec>
  </Actions>
</Task>
"@
	$exists = Get-ScheduledTask -TaskName $t.name -ErrorAction SilentlyContinue
	if ($CheckOnly) {
		Line $t.name ([bool]$exists) ($t.desc + $(if ($exists) { ' / 已存在' } else { ' / 待创建' }))
		continue
	}
	try {
		Register-ScheduledTask -TaskName $t.name -Xml $xml -Force | Out-Null
		Line $t.name $true ($t.desc)
	} catch {
		Line $t.name $false ('注册失败：' + $_.Exception.Message)
		$fail++
	}
}

Write-Host ''
if ($CheckOnly) {
	Write-Host ('检查完毕：FAIL=' + $fail)
	return
}

if ($fail -gt 0) {
	Write-Host ('有 ' + $fail + ' 项没通过，先处理上面标 [ -- ] 的项再安装。')
	return
}

Write-Host '安装完成。'
Write-Host '接下来：正常关机 → 开机时自动解锁 → 进桌面就是解锁状态。'
Write-Host ('日志目录：' + (Join-Path $env:ProgramData 'GpuUnlock'))
Write-Host '想撤销：跑同目录的 卸载.ps1'

# 顺手把桌面图标恢复成已保存的大小（没保存过就是 64px；不重启资源管理器就等下次登录由 GpuUnlockDeskFix 生效）
$deskFix = Join-Path $root 'desk-fix.ps1'
if (Test-Path $deskFix) {
	Write-Host ''
	Write-Host '=== 桌面图标 ==='
	$env:GU_NO_PAUSE = '1'
	try { & $deskFix -NoPause | ForEach-Object { Write-Host ('  ' + $_) } } catch { Write-Host ('  桌面修复跳过：' + $_.Exception.Message) }
	Write-Host '  图标大小可在 GPU 解锁面板里点「图标 大 + / 图标 小 −」随时调整'
}
