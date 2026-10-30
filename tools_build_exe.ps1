# Variant of windows/build.ps1 that takes the Windows Kits root from $env:GU_KITS
# so the build can run against an SDK/WDK extracted with `msiexec /a` (no admin,
# no system-wide install). Original repo scripts are left untouched.
$ErrorActionPreference = "Stop"

$root = $PSScriptRoot
$build = Join-Path $root "build"
$obj = Join-Path $build "obj"
New-Item -ItemType Directory -Force -Path $build, $obj | Out-Null

$vswhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
if (-not (Test-Path $vswhere)) {
	$vswhere = Join-Path $env:ProgramFiles "Microsoft Visual Studio\Installer\vswhere.exe"
}
if (-not (Test-Path $vswhere)) {
	throw "vswhere.exe not found; install Visual Studio Build Tools with the C/C++ workload"
}
$vs = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $vs) {
	throw "no Visual Studio installation with the MSVC x64 toolset was found"
}
$msvc = $null
foreach ($tool in (Get-ChildItem (Join-Path $vs "VC\Tools\MSVC") | Sort-Object Name -Descending)) {
	if (Test-Path (Join-Path $tool.FullName "bin\Hostx64\x64\cl.exe")) {
		$msvc = $tool.FullName
		break
	}
}
if (-not $msvc) {
	throw "cl.exe was not found under $vs"
}

if ($env:GU_KITS) { $kits = $env:GU_KITS } else { $kits = Join-Path ${env:ProgramFiles(x86)} "Windows Kits\10" }
Write-Host "kits=$kits"
$sdk = $null
foreach ($dir in (Get-ChildItem (Join-Path $kits "Include") | Sort-Object Name -Descending)) {
	if (Test-Path (Join-Path $dir.FullName "ucrt\stdio.h")) {
		$sdk = $dir.Name
		break
	}
}
if (-not $sdk) {
	throw "a Windows 10 SDK was not found under $kits"
}
Write-Host "sdk version=$sdk"

$inc = Join-Path $kits "Include\$sdk"
$lib = Join-Path $kits "Lib\$sdk"
$env:INCLUDE = "$msvc\include;$inc\ucrt;$inc\shared;$inc\um;$inc\winrt"
$env:LIB = "$msvc\lib\x64;$lib\ucrt\x64;$lib\um\x64"
$env:PATH = "$msvc\bin\Hostx64\x64;$env:PATH"

$sources = @(
	(Join-Path $root "windows\gpu_unlock_win.c"),
	(Join-Path $root "windows\hal.c"),
	(Join-Path $root "windows\assets_builtin.c"),
	(Join-Path $root "windows\backend_sim.c"),
	(Join-Path $root "windows\backend_win32.c"),
	(Join-Path $root "windows\backend_real.c"),
	(Join-Path $root "kernel\gpu_unlock\unlock_610.c"),
	(Join-Path $root "kernel\gpu_unlock\prep_610.c"),
	(Join-Path $root "kernel\gpu_unlock\layout_610.c"),
	(Join-Path $root "kernel\gpu_unlock\vbios_610.c"),
	(Join-Path $root "kernel\gpu_unlock\gfw_eval.c")
)
$flags = @(
	"/nologo", "/std:c11", "/O2", "/W3",
	"/D__KERNEL__", "/D_CRT_SECURE_NO_WARNINGS", "/DNOMINMAX",
	"/I$(Join-Path $root 'windows\include')",
	"/I$(Join-Path $root 'windows')",
	"/I$(Join-Path $root 'kernel\gpu_unlock')",
	"/experimental:deterministic",
	"/pathmap:${root}\=C:\gpu-unlock-src\"
)
$out = Join-Path $build "gpu_unlock.exe"
$fo = "/Fo" + $obj + "\"

& (Join-Path $msvc "bin\Hostx64\x64\cl.exe") @flags $fo @sources /link /OUT:$out setupapi.lib cfgmgr32.lib advapi32.lib shell32.lib kernel32.lib user32.lib
if ($LASTEXITCODE -ne 0) {
	throw "cl.exe failed with exit code $LASTEXITCODE"
}
Write-Host "built $out"
