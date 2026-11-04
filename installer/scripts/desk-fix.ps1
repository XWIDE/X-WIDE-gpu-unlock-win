# desk-fix.ps1 - restore Windows desktop icon size + icon layer, part of GPU-UNLOCK package
# ASCII only on purpose (no BOM needed).
# Usage:
#   powershell -ExecutionPolicy Bypass -File desk-fix.ps1              # apply saved size, repair if needed
#   powershell -ExecutionPolicy Bypass -File desk-fix.ps1 -IconSize 96 # set and save a new size
#   powershell -ExecutionPolicy Bypass -File desk-fix.ps1 -CheckOnly   # report only, change nothing
#   powershell -ExecutionPolicy Bypass -File desk-fix.ps1 -Stop360     # also stop 360 desktop helper (needs admin)
#   powershell -ExecutionPolicy Bypass -File desk-fix.ps1 -KeepMinutes 30  # keep watching, undo resets

param(
    [int]$IconSize = 0,
    [int]$KeepMinutes = 0,
    [switch]$CheckOnly,
    [switch]$Stop360,
    [switch]$NoPause
)

$ErrorActionPreference = 'Continue'
$logDir = Join-Path $env:ProgramData 'GpuUnlock'
if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$logFile = Join-Path $logDir 'desk-fix.log'
$cfgFile = Join-Path $logDir 'desk.cfg'

function Write-Log([string]$msg) {
    $line = (Get-Date -Format 'yyyyMMdd-HHmmss') + ' ' + $msg
    Add-Content -LiteralPath $logFile -Value $line -Encoding UTF8
    Write-Host $line
}

# ---------- config ----------
$saved = 64
if (Test-Path -LiteralPath $cfgFile) {
    foreach ($l in (Get-Content -LiteralPath $cfgFile -Encoding UTF8)) {
        if ($l -match '^\s*IconSize\s*=\s*(\d+)\s*$') { $saved = [int]$matches[1] }
    }
}
if ($IconSize -le 0) { $IconSize = $saved }
$IconSize = [Math]::Max(32, [Math]::Min(256, $IconSize))

# ---------- helpers ----------
$sig = @"
using System;
using System.Text;
using System.Runtime.InteropServices;
public class DeskFix {
    public delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc f, IntPtr l);
    [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr p, EnumProc f, IntPtr l);
    [DllImport("user32.dll", CharSet = CharSet.Auto)] public static extern int GetClassName(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr h, int m, IntPtr w, IntPtr l);
    public static IntPtr FindDesktopListview() {
        IntPtr found = IntPtr.Zero;
        EnumWindows(delegate(IntPtr h, IntPtr l) {
            IntPtr f2 = IntPtr.Zero;
            EnumChildWindows(h, delegate(IntPtr c, IntPtr l2) {
                StringBuilder sb = new StringBuilder(128);
                GetClassName(c, sb, 128);
                if (sb.ToString() == "SHELLDLL_DefView") {
                    EnumChildWindows(c, delegate(IntPtr g, IntPtr l3) {
                        StringBuilder s2 = new StringBuilder(128);
                        GetClassName(g, s2, 128);
                        if (s2.ToString() == "SysListView32") { found = g; return false; }
                        return true;
                    }, IntPtr.Zero);
                }
                return true;
            }, IntPtr.Zero);
            return found == IntPtr.Zero;
        }, IntPtr.Zero);
        return found;
    }
    // LVM_GETITEMSPACING (0x1033): LOWORD = cx, HIWORD = cy, both in pixels
    public static int[] Spacing() {
        IntPtr lv = FindDesktopListview();
        if (lv == IntPtr.Zero) { return new int[] { -1, -1 }; }
        long r = (long)SendMessage(lv, 0x1033, IntPtr.Zero, IntPtr.Zero);
        int cx = (int)(r & 0xFFFF);
        int cy = (int)((r >> 16) & 0xFFFF);
        return new int[] { cx, cy };
    }
}
"@
try { Add-Type -TypeDefinition $sig -ErrorAction Stop } catch { }

function Get-DesktopIconCount {
    $lv = [DeskFix]::FindDesktopListview()
    if ($lv -eq [IntPtr]::Zero) { return -1 }
    return [int][DeskFix]::SendMessage($lv, 0x1004, [IntPtr]::Zero, [IntPtr]::Zero)
}

function Get-DesktopSpacingCY {
    $s = [DeskFix]::Spacing()
    return [int]$s[1]
}

$bagsKey = 'HKCU:\Software\Microsoft\Windows\Shell\Bags\1\Desktop'
function Get-IconSizeReg {
    if (-not (Test-Path $bagsKey)) { return -1 }
    $v = (Get-ItemProperty -Path $bagsKey -Name IconSize -ErrorAction SilentlyContinue).IconSize
    if ($null -eq $v) { return -1 }
    return [int]$v
}
function Set-IconSizeReg([int]$size) {
    if (-not (Test-Path $bagsKey)) { New-Item -Path $bagsKey -Force | Out-Null }
    New-ItemProperty -Path $bagsKey -Name IconSize -PropertyType DWord -Value $size -Force | Out-Null
}

function Get-DesktopProcess { Get-Process -Name explorer -ErrorAction SilentlyContinue }

function Restart-Desktop {
    Write-Log 'restarting explorer.exe (desktop icon layer)'
    Get-DesktopProcess | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    if (-not (Get-DesktopProcess)) { Start-Process explorer.exe | Out-Null }
    for ($i = 1; $i -le 15; $i++) {
        Start-Sleep -Seconds 1
        $c = Get-DesktopIconCount
        if ($c -ge 0) { Write-Log ('desktop icon layer back after ' + $i + 's, icons=' + $c); return $c }
    }
    Write-Log 'desktop icon layer still missing after restart'
    return -1
}

function Stop-360Desktop {
    $killed = @()
    foreach ($n in @('360DesktopLite64', '360DesktopService64')) {
        foreach ($p in @(Get-Process -Name $n -ErrorAction SilentlyContinue)) {
            try { Stop-Process -Id $p.Id -Force -ErrorAction Stop; $killed += ($n + ':' + $p.Id) }
            catch { Write-Log ('cannot stop ' + $n + ' pid=' + $p.Id + ' : ' + $_.Exception.Message) }
        }
    }
    $svc = Get-Service -Name '360DesktopLiteApp' -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -eq 'Running') {
        try { Stop-Service -Name '360DesktopLiteApp' -Force -ErrorAction Stop; $killed += 'service:360DesktopLiteApp' }
        catch { Write-Log ('cannot stop service 360DesktopLiteApp : ' + $_.Exception.Message) }
    }
    if ($killed.Count -eq 0) { Write-Log '360 desktop helper: nothing running' } else { Write-Log ('stopped: ' + ($killed -join ', ')) }
}

# ---------- main ----------
Write-Log ('=== desk-fix start  desired=' + $IconSize + '  keepMin=' + $KeepMinutes + '  admin=' + ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) + '  checkOnly=' + [bool]$CheckOnly + ' ===')

$cur = Get-IconSizeReg
$icons = Get-DesktopIconCount
Write-Log ('before: registry IconSize=' + $cur + '  live icons=' + $icons)

if (-not $CheckOnly) {
    if ($IconSize -gt 0 -and $cur -ne $IconSize) {
        Set-IconSizeReg $IconSize
        Write-Log ('registry IconSize ' + $cur + ' -> ' + $IconSize + ' (takes effect after explorer restart)')
    }
    if (-not (Test-Path -LiteralPath $cfgFile) -or $true) {
        Set-Content -LiteralPath $cfgFile -Value ('IconSize=' + $IconSize) -Encoding UTF8
    }
    if ($Stop360) { Stop-360Desktop }
}

$needRestart = $false
if ($icons -lt 0) { $needRestart = $true }
if ((-not $CheckOnly) -and $cur -ne $IconSize) { $needRestart = $true }

if ($CheckOnly) {
    Write-Log ('check: registry=' + $cur + ' desired=' + $IconSize + ' icons=' + $icons + ' restartNeeded=' + $needRestart)
} elseif ($needRestart) {
    Restart-Desktop | Out-Null
}

$finalSize = Get-IconSizeReg
$finalIcons = Get-DesktopIconCount
$ok = ($finalSize -eq $IconSize) -and ($finalIcons -ge 0)
Write-Log ('after: registry IconSize=' + $finalSize + '  live icons=' + $finalIcons + '  ok=' + $ok)

# ---------- watch mode ----------
# Windows asks for the icon size through the registry, but a third-party desktop
# helper (360 desktop assistant and friends) can write it back later. Keep an eye
# on it for a while and undo the reset instead of fighting it at boot time only.
if ((-not $CheckOnly) -and $KeepMinutes -gt 0) {
    $baseCY = -1
    if ($finalIcons -ge 0) { $baseCY = Get-DesktopSpacingCY }
    Write-Log ('watch: every 60s for ' + $KeepMinutes + ' min  baselineCY=' + $baseCY)
    $deadline = (Get-Date).AddMinutes($KeepMinutes)
    $fixes = 0
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 60
        $wSize = Get-IconSizeReg
        $wIcons = Get-DesktopIconCount
        if ($wIcons -lt 0) {
            Write-Log ('watch: icon layer missing again, repairing')
            Restart-Desktop | Out-Null
            $fixes++
            continue
        }
        $wCY = Get-DesktopSpacingCY
        $reset = ($wSize -ne $IconSize)
        $shrunk = ($baseCY -gt 0 -and $wCY -gt 0 -and $wCY -lt ($baseCY - 2))
        if ($reset -or $shrunk) {
            Write-Log ('watch: reset detected (registry ' + $wSize + ' wanted ' + $IconSize + ', spacingCY ' + $wCY + ' baseline ' + $baseCY + '), re-applying')
            Set-IconSizeReg $IconSize
            Restart-Desktop | Out-Null
            $baseCY = Get-DesktopSpacingCY
            $fixes++
            continue
        }
        Write-Log ('watch: ok registry=' + $wSize + ' spacingCY=' + $wCY + ' icons=' + $wIcons)
    }
    Write-Log ('watch: finished, corrections=' + $fixes)
}

$finalSize = Get-IconSizeReg
$finalIcons = Get-DesktopIconCount
$finalCY = -1
if ($finalIcons -ge 0) { $finalCY = Get-DesktopSpacingCY }
$ok = ($finalSize -eq $IconSize) -and ($finalIcons -ge 0)
Write-Log ('final: registry IconSize=' + $finalSize + '  spacingCY=' + $finalCY + '  live icons=' + $finalIcons + '  ok=' + $ok)
Write-Log '=== desk-fix end ==='

if (-not $NoPause -and -not $CheckOnly -and $env:GU_NO_PAUSE -ne '1') {
    # only pause when started interactively (double-click), not from a scheduled task
    if ([Environment]::UserInteractive -and $Host.Name -eq 'ConsoleHost') {
        Write-Host ''
        Write-Host ('Result: IconSize=' + $finalSize + '  icons=' + $finalIcons + '  ok=' + $ok)
        Write-Host 'Log: ' $logFile
    }
}
if (-not $ok) { exit 1 }
exit 0
