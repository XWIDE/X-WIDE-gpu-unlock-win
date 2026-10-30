# rescue-enable.ps1 - last-resort: force the display adapter back on if the boot unlock left it disabled.
# Registered as GpuUnlockBootRescue (onstart + 5 min delay, SYSTEM).
$ErrorActionPreference = 'Continue'
$logDir = Join-Path $env:ProgramData 'GpuUnlock'
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
$log = Join-Path $logDir 'rescue-enable.log'
function L([string]$m) { Add-Content -LiteralPath $log -Value ((Get-Date -Format 'yyyyMMdd-HHmmss') + '  ' + $m) -Encoding UTF8 }

L '=== RESCUE START ==='
$g = $null
try { $g = Get-PnpDevice -Class Display -ErrorAction Stop | Where-Object { $_.InstanceId -like 'PCI\*' } | Select-Object -First 1 } catch { L ('enum failed ' + $_.Exception.Message) }
if (-not $g) { L 'no PCI display device found'; return }
L ('gpu=' + $g.Status + ' id=' + $g.InstanceId)
if ($g.Status -ne 'OK') {
	try { Enable-PnpDevice -InstanceId $g.InstanceId -Confirm:$false -ErrorAction Stop; L 'enable sent' } catch { L ('enable failed ' + $_.Exception.Message) }
	Start-Sleep -Seconds 5
	$g2 = Get-PnpDevice -InstanceId $g.InstanceId -ErrorAction SilentlyContinue
	L ('after enable status=' + $(if ($g2) { $g2.Status } else { 'missing' }))
	if ($g2 -and $g2.Status -ne 'OK') {
		$o = & pnputil.exe /restart-device ("`"" + $g.InstanceId + "`"") 2>&1
		L ('pnputil: ' + ($o -join ' '))
	}
}
$v = Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | Select-Object -First 1
L ('mode=' + $v.CurrentHorizontalResolution + 'x' + $v.CurrentVerticalResolution)
L '=== RESCUE END ==='
