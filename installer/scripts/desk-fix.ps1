# desk-fix.ps1 - restore Windows desktop icon size + icon layer, part of GPU-UNLOCK package
# ASCII only on purpose (no BOM needed).
# Usage:
#   powershell -ExecutionPolicy Bypass -File desk-fix.ps1              # apply saved size, repair if needed
#   powershell -ExecutionPolicy Bypass -File desk-fix.ps1 -IconSize 96 # set and save a new size
#   powershell -ExecutionPolicy Bypass -File desk-fix.ps1 -CheckOnly   # report only, change nothing
#   powershell -ExecutionPolicy Bypass -File desk-fix.ps1 -Stop360     # also stop 360 desktop helper (needs admin)
#   powershell -ExecutionPolicy Bypass -File desk-fix.ps1 -KeepMinutes 30  # keep watching, undo resets
#   powershell -ExecutionPolicy Bypass -File desk-fix.ps1 -Reflow      # move icons that sit outside the visible desktop back in

param(
    [int]$IconSize = 0,
    [int]$KeepMinutes = 0,
    [switch]$Reflow,
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

    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
    [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern IntPtr GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("kernel32.dll")] public static extern IntPtr OpenProcess(uint acc, bool inh, uint pid);
    [DllImport("kernel32.dll")] public static extern IntPtr VirtualAllocEx(IntPtr hp, IntPtr addr, IntPtr size, uint type, uint prot);
    [DllImport("kernel32.dll")] public static extern bool VirtualFreeEx(IntPtr hp, IntPtr addr, IntPtr size, uint type);
    [DllImport("kernel32.dll")] public static extern bool ReadProcessMemory(IntPtr hp, IntPtr addr, byte[] buf, IntPtr size, out IntPtr read);
    [DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr h);

    // Icons keep pixel coordinates. When the display scale, resolution or icon size
    // changes, icons that used to fit can end up outside the visible desktop, and
    // Explorer does not pull them back. This moves only the ones that are outside.
    public static string Reflow() {
        IntPtr lv = FindDesktopListview();
        if (lv == IntPtr.Zero) { return "no-listview"; }
        RECT rc;
        if (!GetClientRect(lv, out rc)) { return "no-rect"; }
        int cw = rc.R, ch = rc.B;
        int count = (int)SendMessage(lv, 0x1004, IntPtr.Zero, IntPtr.Zero);
        long sp = (long)SendMessage(lv, 0x1033, IntPtr.Zero, IntPtr.Zero);
        int cx = (int)(sp & 0xFFFF), cy = (int)((sp >> 16) & 0xFFFF);
        if (cx <= 0 || cy <= 0) { return "no-spacing"; }
        int cols = cw / cx, rows = ch / cy;
        if (cols < 1) { cols = 1; }
        if (rows < 1) { rows = 1; }
        if (cols * rows < count) {
            return "capacity " + cols + "x" + rows + "=" + (cols * rows) + " < icons " + count + ", not moved";
        }
        uint pid;
        GetWindowThreadProcessId(lv, out pid);
        IntPtr hp = OpenProcess(0x0008 | 0x0010 | 0x0020 | 0x0400, false, pid);
        if (hp == IntPtr.Zero) { return "no-process"; }
        IntPtr pt = VirtualAllocEx(hp, IntPtr.Zero, (IntPtr)16, 0x3000, 0x04);
        if (pt == IntPtr.Zero) { CloseHandle(hp); return "no-memory"; }
        bool[] used = new bool[cols * rows];
        int off = 0, moved = 0;
        byte[] raw = new byte[8];
        for (int i = 0; i < count; i++) {
            SendMessage(lv, 0x1010, (IntPtr)i, pt);
            IntPtr rd;
            ReadProcessMemory(hp, pt, raw, (IntPtr)8, out rd);
            int x = BitConverter.ToInt32(raw, 0);
            int y = BitConverter.ToInt32(raw, 4);
            int col = (int)Math.Round((double)x / cx);
            int row = (int)Math.Round((double)y / cy);
            bool outside = x < 0 || y < 0 || (x + cx) > cw || (y + cy) > ch;
            if (!outside) {
                if (col >= 0 && col < cols && row >= 0 && row < rows) { used[col * rows + row] = true; }
                continue;
            }
            off++;
            int slot = -1;
            for (int s = 0; s < used.Length; s++) { if (!used[s]) { slot = s; break; } }
            if (slot < 0) { continue; }
            used[slot] = true;
            int nc = slot / rows, nr = slot % rows;
            long lp = (((long)(nr * cy) & 0xFFFF) << 16) | ((long)(nc * cx) & 0xFFFF);
            SendMessage(lv, 0x100F, (IntPtr)i, (IntPtr)lp);
            moved++;
        }
        VirtualFreeEx(hp, pt, IntPtr.Zero, 0x8000);
        CloseHandle(hp);
        return "cols=" + cols + " rows=" + rows + " capacity=" + (cols * rows) + " icons=" + count + " offscreen=" + off + " moved=" + moved;
    }

    // how many icons currently sit outside the visible desktop area
    public static int Offscreen() {
        IntPtr lv = FindDesktopListview();
        if (lv == IntPtr.Zero) { return -1; }
        RECT rc;
        if (!GetClientRect(lv, out rc)) { return -1; }
        int cw = rc.R, ch = rc.B;
        int count = (int)SendMessage(lv, 0x1004, IntPtr.Zero, IntPtr.Zero);
        long sp = (long)SendMessage(lv, 0x1033, IntPtr.Zero, IntPtr.Zero);
        int cx = (int)(sp & 0xFFFF), cy = (int)((sp >> 16) & 0xFFFF);
        if (cx <= 0 || cy <= 0) { return -1; }
        uint pid;
        GetWindowThreadProcessId(lv, out pid);
        IntPtr hp = OpenProcess(0x0008 | 0x0010 | 0x0400, false, pid);
        if (hp == IntPtr.Zero) { return -1; }
        IntPtr pt = VirtualAllocEx(hp, IntPtr.Zero, (IntPtr)16, 0x3000, 0x04);
        if (pt == IntPtr.Zero) { CloseHandle(hp); return -1; }
        int off = 0;
        byte[] raw = new byte[8];
        for (int i = 0; i < count; i++) {
            SendMessage(lv, 0x1010, (IntPtr)i, pt);
            IntPtr rd;
            ReadProcessMemory(hp, pt, raw, (IntPtr)8, out rd);
            int x = BitConverter.ToInt32(raw, 0);
            int y = BitConverter.ToInt32(raw, 4);
            if (x < 0 || y < 0 || (x + cx) > cw || (y + cy) > ch) { off++; }
        }
        VirtualFreeEx(hp, pt, IntPtr.Zero, 0x8000);
        CloseHandle(hp);
        return off;
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

function Get-HideIcons {
    $k = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
    $v = (Get-ItemProperty -Path $k -Name HideIcons -ErrorAction SilentlyContinue).HideIcons
    if ($null -eq $v) { return 0 }
    return [int]$v
}
function Set-HideIcons([int]$v) {
    $k = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
    if (-not (Test-Path $k)) { return }
    Set-ItemProperty -Path $k -Name HideIcons -Value $v -Type DWord -ErrorAction SilentlyContinue
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

# A desktop helper (360 desktop assistant and friends) may also switch "show desktop
# icons" off. Icons hidden = empty desktop, so treat it as damage and undo it.
$hideBroken = $false
$hideNow = Get-HideIcons
if ((-not $CheckOnly) -and $hideNow -ne 0) {
    Write-Log ('desktop icons were hidden (HideIcons=' + $hideNow + '), turning them back on')
    Set-HideIcons 0
    $hideBroken = $true
}

$needRestart = $false
if ($icons -lt 0) { $needRestart = $true }
if ((-not $CheckOnly) -and $cur -ne $IconSize) { $needRestart = $true }
if ($hideBroken) { $needRestart = $true }

if ($CheckOnly) {
    Write-Log ('check: registry=' + $cur + ' desired=' + $IconSize + ' icons=' + $icons + ' hideIcons=' + (Get-HideIcons) + ' restartNeeded=' + $needRestart + ' offscreen=' + [DeskFix]::Offscreen())
} elseif ($needRestart) {
    Restart-Desktop | Out-Null
}

if ((-not $CheckOnly) -and $Reflow) {
    Write-Log ('reflow: ' + [DeskFix]::Reflow())
    Write-Log ('reflow: offscreen now ' + [DeskFix]::Offscreen())
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
        $wHide = Get-HideIcons
        if ($wHide -ne 0) {
            Write-Log ('watch: desktop icons were hidden (HideIcons=' + $wHide + '), turning them back on')
            Set-HideIcons 0
            Restart-Desktop | Out-Null
            if ($Reflow) { Write-Log ('watch: reflow: ' + [DeskFix]::Reflow()) }
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
            if ($Reflow) { Write-Log ('watch: reflow: ' + [DeskFix]::Reflow()) }
            $baseCY = Get-DesktopSpacingCY
            $fixes++
            continue
        }
        $wOff = -1
        if ($Reflow) { $wOff = [DeskFix]::Offscreen() }
        if ($Reflow -and $wOff -gt 0) {
            Write-Log ('watch: ' + $wOff + ' icons outside the visible desktop, reflowing')
            Write-Log ('watch: reflow: ' + [DeskFix]::Reflow())
            $fixes++
            continue
        }
        Write-Log ('watch: ok registry=' + $wSize + ' spacingCY=' + $wCY + ' icons=' + $wIcons + ' hideIcons=0 offscreen=' + $wOff)
    }
    Write-Log ('watch: finished, corrections=' + $fixes)
}

$finalSize = Get-IconSizeReg
$finalIcons = Get-DesktopIconCount
$finalCY = -1
if ($finalIcons -ge 0) { $finalCY = Get-DesktopSpacingCY }
$ok = ($finalSize -eq $IconSize) -and ($finalIcons -ge 0) -and ((Get-HideIcons) -eq 0)
Write-Log ('final: registry IconSize=' + $finalSize + '  spacingCY=' + $finalCY + '  live icons=' + $finalIcons + '  hideIcons=' + (Get-HideIcons) + '  ok=' + $ok)
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
