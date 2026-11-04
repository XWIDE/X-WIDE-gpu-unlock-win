# Build the publishable tree: F:\gpu-unlock-win\release
# Copies sources + docs + installer scripts only. No binaries, no firmware blobs.
# Safe to re-run: it overwrites files in the staging tree, touches nothing outside it.

$ErrorActionPreference = 'Stop'
$src = 'F:\gpu-unlock-win'
$rel = Join-Path $src 'release'

New-Item -ItemType Directory -Path $rel -Force | Out-Null

$rootFiles = @(
    'LICENSE', 'CONTRIBUTING.md', 'SECURITY.md',
    'VERSION', 'Makefile', 'tools_build_drv.ps1', 'tools_build_exe.ps1',
    'tools_extract_src.py', 'tools_sign.ps1', 'tools_v67_node.cjs', 'tools_stage_release.ps1'
)
foreach ($f in $rootFiles) {
    $p = Join-Path $src $f
    if (Test-Path $p) { Copy-Item $p (Join-Path $rel $f) -Force }
    else { Write-Host ("skip missing: " + $f) }
}

# Repo landing page comes from docs\REPO-README.md; upstream READMEs are kept renamed.
$repoReadme = Join-Path $src 'docs\REPO-README.md'
if (Test-Path $repoReadme) { Copy-Item $repoReadme (Join-Path $rel 'README.md') -Force }
else { Write-Host 'skip missing: docs\REPO-README.md' }
foreach ($pair in @(@('README.md', 'README.upstream.md'), @('README.zh-CN.md', 'README.upstream.zh-CN.md'))) {
    $from = Join-Path $src $pair[0]
    if (Test-Path $from) { Copy-Item $from (Join-Path $rel $pair[1]) -Force }
}

$sourceDirs = @('kernel', 'windows', 'tests', 'firmware', 'docs', 'licenses')
foreach ($d in $sourceDirs) {
    $from = Join-Path $src $d
    if (-not (Test-Path $from)) { continue }
    $to = Join-Path $rel $d
    $null = robocopy $from $to /E /NFL /NDL /NJH /NJS /XF *.sys *.exe *.bin *.obj *.o *.log *.pdb *.lib *.exp /XD .vs build obj __pycache__
}

$installer = Join-Path $rel 'installer'
$null = robocopy (Join-Path $src 'dist\share') $installer /E /NFL /NDL /NJH /NJS
$scriptDir = Join-Path $installer 'scripts'
New-Item -ItemType Directory -Path $scriptDir -Force | Out-Null
$distScripts = @(
    'boot-unlock.ps1', 'gpu-disable.ps1', 'rescue-enable.ps1',
    'gpu-panel-v3.ps1', 'GPU-panel-v3.bat', 'enable-test-signing.ps1', 'bf16_probe.py',
    'desk-fix.ps1'
)
foreach ($f in $distScripts) {
    $p = Join-Path $src ('dist\' + $f)
    if (Test-Path $p) { Copy-Item $p (Join-Path $scriptDir $f) -Force }
    else { Write-Host ("skip missing: dist\" + $f) }
}

$gitignore = @'
# build / runtime artifacts
build/
*.sys
*.exe
*.obj
*.o
*.pdb
*.lib
*.exp
*.log

# firmware blobs (NVIDIA copyright, never redistribute)
gpu-unlock/
*.bin

# local scratch
_tmp/
_shots/
__pycache__/
*.pyc
*.bak
*.bak-*
.deleted-*/
'@
$gitignore | Out-File -LiteralPath (Join-Path $rel '.gitignore') -Encoding ASCII

$files = Get-ChildItem $rel -Recurse -File
$kb = [math]::Round((($files | Measure-Object Length -Sum).Sum) / 1KB, 1)
Write-Host ('staged: ' + $files.Count + ' files, ' + $kb + ' KB -> ' + $rel)
