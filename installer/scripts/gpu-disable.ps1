# gpu-disable.ps1 - disable the display adapter when Windows is shutting down, so the
# next boot starts cold and the boot-time unlock has a card no driver has touched yet.
# Registered as GpuUnlockOff (SYSTEM, event 1074 = shutdown initiated).
$ErrorActionPreference = 'Continue'
$logDir = Join-Path $env:ProgramData 'GpuUnlock'
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
$log = Join-Path $logDir 'disable-at-shutdown.log'
function L([string]$m) { Add-Content -LiteralPath $log -Value ((Get-Date -Format 'yyyyMMdd-HHmmss') + '  ' + $m) -Encoding UTF8 }

L '=== SHUTDOWN DISABLE START ==='
$g = $null
try { $g = Get-PnpDevice -Class Display -ErrorAction Stop | Where-Object { $_.InstanceId -like 'PCI\*' } | Select-Object -First 1 } catch { L ('enum failed ' + $_.Exception.Message) }
if (-not $g) { L 'no PCI display device'; return }
L ('gpu=' + $g.Status + ' id=' + $g.InstanceId)
if ($g.Status -eq 'OK') {
	try { Disable-PnpDevice -InstanceId $g.InstanceId -Confirm:$false -ErrorAction Stop; L 'disable sent' } catch { L ('disable failed ' + $_.Exception.Message) }
	Start-Sleep -Seconds 2
	$g2 = Get-PnpDevice -InstanceId $g.InstanceId -ErrorAction SilentlyContinue
	L ('after=' + $(if ($g2) { $g2.Status } else { 'missing' }))
} else {
	L 'already disabled'
}
L '=== SHUTDOWN DISABLE END ==='
