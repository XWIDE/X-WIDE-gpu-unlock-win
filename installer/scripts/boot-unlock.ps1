# boot-unlock.ps1 - run the cold-path unlock at boot, then guarantee the display comes back.
# Runs as SYSTEM via a startup scheduled task (GpuUnlockBoot).
# Flow: wait for the card, cold unlock, re-enable the adapter no matter what, log everything.
param(
	[string]$Root = 'F:\gpu-unlock-win\dist',
	[int]$TimeoutSec = 240
)
$ErrorActionPreference = 'Continue'
$logDir = Join-Path $env:ProgramData 'GpuUnlock'
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$log = Join-Path $logDir ("boot-unlock-$stamp.log")
$out = Join-Path $logDir ("boot-unlock-$stamp.out.txt")
$err = Join-Path $logDir ("boot-unlock-$stamp.err.txt")
function L([string]$m) { Add-Content -LiteralPath $log -Value ((Get-Date -Format 'HH:mm:ss') + '  ' + $m) -Encoding UTF8 }

function Get-Gpu([string]$cls) {
	try { return (Get-PnpDevice -Class $cls -ErrorAction Stop | Where-Object { $_.InstanceId -like 'PCI\*' } | Select-Object -First 1) } catch { return $null }
}
function Ensure-Up([string]$why) {
	$g = Get-Gpu 'Display'
	L ("ensure-up ({0}) status={1}" -f $why, $(if ($g) { $g.Status } else { 'none' }))
	if ($g -and $g.Status -ne 'OK') {
		try { Enable-PnpDevice -InstanceId $g.InstanceId -Confirm:$false -ErrorAction Stop; L 'enable sent' } catch { L ('enable failed ' + $_.Exception.Message) }
		Start-Sleep -Seconds 5
		$g = Get-Gpu 'Display'
		L ('after enable status=' + $(if ($g) { $g.Status } else { 'none' }))
	}
}

L '=== BOOT UNLOCK START ==='
L ('user=' + $env:USERNAME + ' root=' + $Root)

# 1. wait for the driver service to be ready (it was deleted after the last test)
$svc = $null
for ($i = 0; $i -lt 30; $i++) { $svc = Get-Service nvlddmkm -ErrorAction SilentlyContinue; if ($svc) { break }; Start-Sleep -Seconds 2 }
L ('nvlddmkm=' + $(if ($svc) { $svc.Status } else { 'missing' }))
Get-Gpu 'Display' | ForEach-Object { L ('gpu status=' + $_.Status + ' id=' + $_.InstanceId) }

# 1b. safety gate: the cold path is only valid while no driver has bound the card.
# An adapter that is Enabled/OK at boot means nvlddmkm already owns it; running the
# transaction then is exactly what used to black the screen, so skip it entirely.
$gpu0 = Get-Gpu 'Display'
$cold = [bool]($gpu0 -and $gpu0.Status -ne 'OK')
L ('cold=' + $cold + ' (expect gpu status Error/disabled)')
if (-not $cold) {
	L 'NOT COLD: unlock skipped, no hardware access attempted; card stays locked'
	L '=== BOOT UNLOCK END ==='
	return
}

# 2. run the cold-path unlock with output straight to disk
$exe = Join-Path $Root 'gpu_unlock.exe'
L ('exe exists=' + (Test-Path $exe))
if (Test-Path $exe) {
	# 2a. read-only probe first so the at-boot selector state is preserved
	$pre = Join-Path $logDir ("probe-pre-$stamp.txt")
	try {
		$pp0 = Start-Process -FilePath $exe -ArgumentList @('real', '--probe') -RedirectStandardOutput $pre -RedirectStandardError ($pre + '.err') -NoNewWindow -PassThru
		$pp0.WaitForExit(90000) | Out-Null
		L ('--- probe before (exit=' + $pp0.ExitCode + ') ---')
		if (Test-Path $pre) { foreach ($ln in [IO.File]::ReadAllLines($pre)) { if ($ln -match 'SS0|SS1|WPR2|state:') { L ('  | ' + $ln.Trim()) } } }
		if (Test-Path ($pre + '.err')) { foreach ($ln in [IO.File]::ReadAllLines($pre + '.err')) { if ($ln.Trim() -ne '') { L ('  err| ' + $ln.Trim()) } } }
	} catch { L ('pre probe error ' + $_.Exception.Message) }

	$sw = [Diagnostics.Stopwatch]::StartNew()
	try {
		$p = Start-Process -FilePath $exe -ArgumentList @('real', '--cold', '--yes') -RedirectStandardOutput $out -RedirectStandardError $err -NoNewWindow -PassThru
		if (-not $p.WaitForExit($TimeoutSec * 1000)) { L 'child timeout, killing'; try { $p.Kill() } catch { } }
		$sw.Stop()
		L ('cold unlock exit=' + $p.ExitCode + ' sec=' + [int]$sw.Elapsed.TotalSeconds)
	} catch { L ('cold unlock launch error: ' + $_.Exception.Message) }
	foreach ($f in @($out, $err)) {
		L ('--- ' + (Split-Path $f -Leaf) + ' ---')
		if (Test-Path $f) {
			$lines = [IO.File]::ReadAllLines($f)
			foreach ($ln in $lines) { if ($ln.Trim() -ne '') { Add-Content -LiteralPath $log -Value ('  | ' + $ln) -Encoding UTF8 } }
		} else { L '  (no file)' }
	}
}

# 3. always bring the display back, whatever happened above
Ensure-Up 'after cold unlock'
for ($i = 1; $i -le 3; $i++) {
	Start-Sleep -Seconds 4
	$g = Get-Gpu 'Display'
	if ($g -and $g.Status -eq 'OK') { L ('retry ' + $i + ': gpu OK'); break }
	L ('retry ' + $i + ': gpu=' + $(if ($g) { $g.Status } else { 'none' }))
	if ($g) {
		try { Enable-PnpDevice -InstanceId $g.InstanceId -Confirm:$false -ErrorAction Stop } catch { L ('  enable failed ' + $_.Exception.Message) }
		Start-Sleep -Seconds 3
		$o = & pnputil.exe /restart-device ("`"" + $g.InstanceId + "`"") 2>&1
		L ('  pnputil: ' + ($o -join ' '))
	}
}
Ensure-Up 'verify'
$v = Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | Select-Object -First 1
L ('mode=' + $v.CurrentHorizontalResolution + 'x' + $v.CurrentVerticalResolution)

# 4. read back the selectors so the next boot can be compared
try {
	$pb = Join-Path $logDir ("probe-$stamp.txt")
	$pp = Start-Process -FilePath $exe -ArgumentList @('real', '--probe') -RedirectStandardOutput $pb -RedirectStandardError ($pb + '.err') -NoNewWindow -PassThru
	$pp.WaitForExit(90000) | Out-Null
	L '--- probe after ---'
	if (Test-Path $pb) { foreach ($ln in [IO.File]::ReadAllLines($pb)) { if ($ln -match 'SS0|SS1|WPR2|state:') { L ('  | ' + $ln.Trim()) } } }
} catch { L ('probe error ' + $_.Exception.Message) }
L '=== BOOT UNLOCK END ==='
