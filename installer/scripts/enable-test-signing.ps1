# Enables Windows test signing and installs the self-signed GpuUnlock certificate.
#
# It works on two kinds of machine:
#   1) BUILD machine   - the private key still lives in Cert:\CurrentUser\My,
#                        so the public certificate is exported from it.
#   2) TARGET machine  - only the shipped public gpuunlock-test.cer is present,
#                        so that file is imported instead.
#
# Run it from the package folder (the .cer sits next to this script or one level up).
# Self-elevates: double-click the .bat launcher instead of typing anything.

param([switch]$NoPause)

$ErrorActionPreference = 'Stop'

$id = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($id)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
	$q = [char]34
	$argList = '-NoProfile -ExecutionPolicy Bypass -File ' + $q + $PSCommandPath + $q
	if ($NoPause) { $argList = $argList + ' -NoPause' }
	Start-Process powershell -Verb RunAs -ArgumentList $argList
	exit
}

$subject = 'CN=GpuUnlock Test Signing'

# locate the shipped public certificate
$cerPath = Join-Path $PSScriptRoot 'gpuunlock-test.cer'
if (-not (Test-Path $cerPath)) {
	$alt = Join-Path (Split-Path $PSScriptRoot -Parent) 'gpuunlock-test.cer'
	if (Test-Path $alt) { $cerPath = $alt }
}

$cert = Get-ChildItem Cert:\CurrentUser\My |
	Where-Object { $_.Subject -eq $subject -and $_.HasPrivateKey } |
	Select-Object -First 1

if ($cert) {
	Write-Host "[1/3] build machine: private key found, exporting the public certificate"
	Export-Certificate -Cert $cert -FilePath $cerPath | Out-Null
	Write-Host ("      exported -> " + $cerPath)
} elseif (Test-Path $cerPath) {
	Write-Host "[1/3] target machine: using the shipped public certificate"
	Write-Host ("      file -> " + $cerPath)
} else {
	Write-Host "[1/3] ERROR: no certificate found."
	Write-Host ("      expected: " + $cerPath)
	Write-Host "      gpuunlock-test.cer ships with the portable package; put it next to this script."
	Write-Host "      If you build from source, run tools_sign.ps1 first - that creates the certificate."
	if (-not $NoPause) { Read-Host "press Enter" }
	exit 1
}

$x = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($cerPath)
Write-Host ("      certificate subject: " + $x.Subject)
Write-Host ("      thumbprint: " + $x.Thumbprint)

try { $sb = Confirm-SecureBootUEFI } catch { $sb = $null }
if ($sb -eq $true) {
	Write-Host ""
	Write-Host "!! Secure Boot is ON. The self-signed driver will NOT load until you turn it off"
	Write-Host "   in the UEFI/BIOS setup. Test signing cannot override Secure Boot."
	Write-Host ""
}

$storeFail = $false
Write-Host "[2/3] installing the certificate into the machine stores"
$tp = $x.Thumbprint
foreach ($storeName in "Root", "TrustedPublisher") {
	certutil -addstore -f $storeName $cerPath | Out-Null
	$hit = @(Get-ChildItem ("Cert:\LocalMachine\" + $storeName) | Where-Object { $_.Thumbprint -eq $tp })
	if ($hit.Count -gt 0) {
		Write-Host ("      [LocalMachine\" + $storeName + "] OK, thumbprint present")
	} else {
		Write-Host ("      [LocalMachine\" + $storeName + "] FAILED, thumbprint missing - run this script as administrator")
		$storeFail = $true
	}
}
if ($storeFail) {
	Write-Host "      the driver will report Win32 error 577 without the certificate, stopping here."
	if (-not $NoPause) { Read-Host "press Enter" }
	exit 1
}

Write-Host "[3/3] enabling test signing"
bcdedit /set testsigning on
if ($LASTEXITCODE -ne 0) {
	Write-Host ("      bcdedit failed with exit code " + $LASTEXITCODE)
	Write-Host "      If it mentions Secure Boot, turn Secure Boot off in the UEFI setup first."
	if (-not $NoPause) { Read-Host "press Enter" }
	exit 1
}

Write-Host ""
Write-Host "== result =="
bcdedit /enum "{current}" | Select-String -Pattern "testsigning", "safeboot" | ForEach-Object { Write-Host ("      " + $_) }
Write-Host ""
Write-Host "Next: reboot once, then run installer\install.ps1 (or INSTALL.bat)."
Write-Host "After that, every normal shutdown+power-on unlocks the card automatically."
Write-Host "To undo: bcdedit /set testsigning off  (then reboot)"
if (-not $NoPause) { Read-Host "press Enter" }
