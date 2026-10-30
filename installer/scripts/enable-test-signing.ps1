# Enables Windows test signing so the self-signed gpuunlock.sys can load.
# Self-elevates: double-click 开启测试签名.bat instead of typing anything.
$ErrorActionPreference = "Stop"

$id = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($id)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
	Start-Process powershell -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
	exit
}

# The kernel consults the machine certificate stores, not the current user's,
# so the self-signed certificate must also live in LocalMachine\Root and
# LocalMachine\TrustedPublisher. Without this the driver can keep failing with
# Win32 error 577 even after test signing is on.
$subject = "CN=GpuUnlock Test Signing"
$cert = Get-ChildItem Cert:\CurrentUser\My |
	Where-Object { $_.Subject -eq $subject -and $_.HasPrivateKey } |
	Select-Object -First 1
if (-not $cert) {
	Write-Host "signing certificate not found; run tools_sign.ps1 first"
	Read-Host "press Enter"
	exit 1
}
$cer = Join-Path $PSScriptRoot "gpuunlock-test.cer"
Export-Certificate -Cert $cert -FilePath $cer | Out-Null
Write-Host "== installing the certificate into the machine stores =="
foreach ($storeName in "Root","TrustedPublisher") {
	certutil -addstore -f $storeName $cer | Select-String -Pattern "Cert Add|Added|Error|ERROR" | ForEach-Object { Write-Host "  $_" }
}

Write-Host "== current boot configuration =="
bcdedit /enum "{current}" | Select-String -Pattern "testsigning","safeboot"

Write-Host "== enabling test signing =="
bcdedit /set testsigning on
if ($LASTEXITCODE -ne 0) {
	Write-Host "bcdedit failed with exit code $LASTEXITCODE"
	Write-Host "If it says Secure Boot is enabled, turn Secure Boot off in the UEFI setup first."
	Read-Host "press Enter"
	exit 1
}

Write-Host "== result =="
bcdedit /enum "{current}" | Select-String -Pattern "testsigning"
Write-Host ""
Write-Host "Now reboot. After the reboot double-click GPU解锁.bat."
Write-Host "If it refuses with WPR2 / cold path (the driver already initialised the card"
Write-Host "at boot), use GPU解锁-pre-flr.bat instead."
Write-Host "To undo later: bcdedit /set testsigning off  (then reboot)"
Read-Host "press Enter"
