# Non-elevated variant of windows/sign_driver.ps1: same certificate + signtool
# flow, minus the script's own administrator self-check (the certificate lives in
# CurrentUser stores, which do not require elevation) and with the Windows Kits
# root taken from $env:GU_KITS so signtool is found in the msiexec /a tree.
# bcdedit (test signing) still needs a real administrator console.
param(
	[switch]$EnableTestSigning,
	[string]$Sys = (Join-Path $PSScriptRoot "build\gpuunlock.sys")
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $Sys)) {
	throw "$Sys not found; run tools_build_drv.ps1 first"
}

$subject = "CN=GpuUnlock Test Signing"
$cert = Get-ChildItem Cert:\CurrentUser\My |
	Where-Object { $_.Subject -eq $subject -and $_.HasPrivateKey } |
	Select-Object -First 1
if (-not $cert) {
	Write-Host "creating self-signed code-signing certificate"
	$cert = New-SelfSignedCertificate -Type CodeSigningCert -Subject $subject `
		-CertStoreLocation Cert:\CurrentUser\My -KeyExportPolicy Exportable `
		-NotAfter (Get-Date).AddYears(5)
}
Write-Host "cert $($cert.Thumbprint)"

$thumbprint = $cert.Thumbprint
foreach ($storeName in "Root","TrustedPublisher") {
	$store = New-Object Security.Cryptography.X509Certificates.X509Store -ArgumentList $storeName, "CurrentUser"
	$store.Open("ReadWrite")
	if (-not ($store.Certificates | Where-Object { $_.Thumbprint -eq $thumbprint })) {
		$store.Add($cert)
		Write-Host "added certificate to CurrentUser\$storeName"
	}
	$store.Close()
}

if ($env:GU_KITS) { $kits = $env:GU_KITS } else { $kits = Join-Path ${env:ProgramFiles(x86)} "Windows Kits\10" }
$signtool = Get-ChildItem (Join-Path $kits "bin") -Recurse -Filter signtool.exe |
	Where-Object { $_.FullName -like "*\x64\signtool.exe" } |
	Sort-Object FullName -Descending |
	Select-Object -First 1
if (-not $signtool) {
	throw "signtool.exe was not found under $kits\bin"
}
Write-Host "signtool=$($signtool.FullName)"

& $signtool.FullName sign /fd SHA256 /sha1 $thumbprint $Sys
if ($LASTEXITCODE -ne 0) {
	throw "signtool sign failed with exit code $LASTEXITCODE"
}
& $signtool.FullName verify /pa /v $Sys
if ($LASTEXITCODE -ne 0) {
	throw "signtool verify failed with exit code $LASTEXITCODE"
}
Write-Host "signed $Sys"

if ($EnableTestSigning) {
	bcdedit /set testsigning on
	if ($LASTEXITCODE -ne 0) {
		throw "bcdedit failed with exit code $LASTEXITCODE (needs an elevated console)"
	}
	Write-Host "test signing enabled; reboot before loading gpuunlock.sys"
}

$testsigning = bcdedit /enum "{current}" 2>$null | Select-String -Pattern "testsigning"
if ($testsigning -match "Yes") {
	Write-Host "test signing is ON"
} else {
	Write-Host "test signing is OFF; run bcdedit /set testsigning on in an elevated console and reboot"
}
