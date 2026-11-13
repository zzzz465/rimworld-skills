<#
.SYNOPSIS
  Runs a RimWorld 1.7 step script in a separate, hidden and muted game instance.

.DESCRIPTION
  Copies the user's Config (without the FastLoader cache) and warm caches into a temporary save data
  folder, zeroes every volume in that copy's Prefs.xml, optionally copies a save, puts the test driver
  into Mods for the length of the run, launches the game with -NoWindow (or -Headless), waits, and
  cleans up: driver removed, the user's Player.log restored, temp folder deleted. The user's own
  Config, Prefs and saves are never written.

.EXAMPLE
  run-test.ps1 -Script C:\tmp\steps.txt -Enable jungooji.dailyworkstats
#>
param(
    [Parameter(Mandatory = $true)][string]$Script,
    # Save in the user's Saves folder, file name without .rws. Default: newest save that is not an autosave.
    [string]$Save = '',
    # Start with -quicktest (random small colony) instead of a save. The script then starts with `waitmap`.
    [switch]$QuickTest,
    # packageIds to switch on / off in the test instance's ModsConfig only.
    [string[]]$Enable = @(),
    [string[]]$Disable = @(),
    # No rendering at all: faster and lighter, but `shot` fails.
    [switch]$Headless,
    [string]$Out = '',
    [int]$TimeoutMin = 25,
    # Run even though the user's game is open. Both instances then write the same Player.log.
    [switch]$AllowWhileRunning,
    [switch]$KeepData
)
$ErrorActionPreference = 'Stop'

$Game = 'C:\Program Files (x86)\Steam\steamapps\common\RimWorld'
$User = Join-Path $env:USERPROFILE 'AppData\LocalLow\Ludeon Studios\RimWorld by Ludeon Studios'
$Skill = Split-Path -Parent $PSScriptRoot
$DriverSrc = Join-Path $Skill 'driver'
$DriverId = 'jungooji.backgroundtestdriver'
$DriverDir = Join-Path $Game 'Mods\zz-BackgroundTestDriver'
$Root = Join-Path $env:TEMP 'rimworld-background-test'
$Stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$Data = Join-Path $Root "data-$Stamp"
if (-not $Out) { $Out = Join-Path $Root "out-$Stamp" }
$Lock = Join-Path $Root 'run.lock'

$Script = (Resolve-Path $Script).Path
if (-not (Test-Path (Join-Path $DriverSrc '1.7\Assemblies\BackgroundTestDriver.dll'))) { throw "Driver not built: $DriverSrc" }
$running = @(Get-Process RimWorld -ErrorAction SilentlyContinue)
if ($running.Count -gt 0 -and -not $AllowWhileRunning) {
    throw 'RimWorld is already running. Close it, or pass -AllowWhileRunning (its Player.log will then mix with the test).'
}

New-Item -ItemType Directory -Force $Root | Out-Null
New-Item -ItemType Directory $Lock | Out-Null   # fails while another run holds it

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

// Reads the peak level of a process's audio sessions on the default output device (read-only:
// nothing here changes a volume, so Windows' per-app volume memory is untouched).
public static class AudioPeak
{
    [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")] class MMDeviceEnumerator { }

    [Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDeviceEnumerator
    {
        int NotImpl1();
        [PreserveSig] int GetDefaultAudioEndpoint(int dataFlow, int role, out IMMDevice device);
    }

    [Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDevice
    {
        [PreserveSig] int Activate(ref Guid iid, int clsCtx, IntPtr activationParams, [MarshalAs(UnmanagedType.IUnknown)] out object iface);
    }

    [Guid("77AA99A0-1BD6-484F-8BC7-2C654C9A9B6F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioSessionManager2
    {
        int NotImpl1();
        int NotImpl2();
        [PreserveSig] int GetSessionEnumerator(out IAudioSessionEnumerator sessions);
    }

    [Guid("E2F5BB11-0570-40CA-ACDD-3AA01277DEE8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioSessionEnumerator
    {
        [PreserveSig] int GetCount(out int count);
        [PreserveSig] int GetSession(int index, out IAudioSessionControl2 session);
    }

    [Guid("bfb7ff88-7239-4fc9-8fa2-07c950be9c6d"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioSessionControl2
    {
        int NotImpl0(); int NotImpl1(); int NotImpl2(); int NotImpl3(); int NotImpl4();
        int NotImpl5(); int NotImpl6(); int NotImpl7(); int NotImpl8(); int NotImpl9(); int NotImpl10();
        [PreserveSig] int GetProcessId(out uint pid);
    }

    [Guid("C02216F6-8C67-4B5B-9D00-D008E73E0064"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioMeterInformation
    {
        [PreserveSig] int GetPeakValue(out float peak);
    }

    // Highest peak among the process's sessions, or -1 when it has no session yet.
    public static float Of(int pid)
    {
        try
        {
            var enumerator = (IMMDeviceEnumerator)new MMDeviceEnumerator();
            IMMDevice device;
            if (enumerator.GetDefaultAudioEndpoint(0, 1, out device) != 0) return -1f;
            Guid iid = typeof(IAudioSessionManager2).GUID;
            object o;
            if (device.Activate(ref iid, 23, IntPtr.Zero, out o) != 0) return -1f;
            IAudioSessionEnumerator sessions;
            ((IAudioSessionManager2)o).GetSessionEnumerator(out sessions);
            int count;
            sessions.GetCount(out count);
            float best = -1f;
            for (int i = 0; i < count; i++)
            {
                IAudioSessionControl2 session;
                sessions.GetSession(i, out session);
                uint owner;
                session.GetProcessId(out owner);
                if (owner != (uint)pid) continue;
                float peak;
                ((IAudioMeterInformation)session).GetPeakValue(out peak);
                best = Math.Max(best, peak);
            }
            return best;
        }
        catch { return -1f; }
    }
}
'@ -ErrorAction SilentlyContinue

$logBackup = Join-Path $Root "user-logs-$Stamp"
$restoreLogs = $running.Count -eq 0
try {
    New-Item -ItemType Directory -Force $Out, $logBackup, (Join-Path $Data 'Saves') | Out-Null
    foreach ($f in 'Player.log', 'Player-prev.log') {
        $p = Join-Path $User "Logs\$f"
        if (Test-Path $p) { Copy-Item $p $logBackup -Force }
    }

    # Config without the FastLoader cache (unused on 1.7, ~900 MB); warm texture and shader caches.
    robocopy (Join-Path $User 'Config') (Join-Path $Data 'Config') /E /XD FastLoader /NFL /NDL /NJH /NJS | Out-Null
    foreach ($d in 'TextureCache', 'ShaderCache', 'HardwareProfile') {
        $src = Join-Path $User $d
        if (Test-Path $src) { robocopy $src (Join-Path $Data $d) /E /NFL /NDL /NJH /NJS | Out-Null }
    }

    # Silence: every volume to zero in this copy of the preferences only.
    $prefsPath = Join-Path $Data 'Config\Prefs.xml'
    $prefs = [IO.File]::ReadAllText($prefsPath)
    foreach ($v in 'volumeMaster', 'volumeGame', 'volumeMusic', 'volumeAmbient', 'volumeUI') {
        if ($prefs -match "<$v>") { $prefs = $prefs -replace "<$v>[^<]*</$v>", "<$v>0</$v>" }
        else { $prefs = $prefs -replace '<PrefsData>', "<PrefsData>`r`n  <$v>0</$v>" }
    }
    $prefs = $prefs -replace '<runInBackground>[^<]*</runInBackground>', '<runInBackground>True</runInBackground>'
    [IO.File]::WriteAllText($prefsPath, $prefs, (New-Object Text.UTF8Encoding($false)))

    $saveInfo = 'quicktest'
    if (-not $QuickTest) {
        if ($Save) { $saveFile = Get-Item (Join-Path $User "Saves\$Save.rws") }
        else {
            $saveFile = Get-ChildItem (Join-Path $User 'Saves') -Filter *.rws |
                Where-Object { $_.Name -notlike 'Autosave*' -and $_.Name -notlike 'BadEvent*' } |
                Sort-Object LastWriteTime -Descending | Select-Object -First 1
        }
        Copy-Item $saveFile.FullName (Join-Path $Data 'Saves\test.rws')
        $saveInfo = $saveFile.Name
    }

    # ModsConfig of the copy: requested changes, driver last.
    $mcPath = Join-Path $Data 'Config\ModsConfig.xml'
    $mc = [IO.File]::ReadAllText($mcPath)
    foreach ($id in $Disable) { $mc = $mc -replace "\s*<li>$([regex]::Escape($id.ToLowerInvariant()))</li>", '' }
    foreach ($id in @($Enable) + $DriverId) {
        $lid = $id.ToLowerInvariant()
        if ($mc -notmatch "<li>$([regex]::Escape($lid))</li>") { $mc = $mc -replace '(\s*)</activeMods>', "`r`n    <li>$lid</li>`$1</activeMods>" }
    }
    [IO.File]::WriteAllText($mcPath, $mc, (New-Object Text.UTF8Encoding($false)))

    if (Test-Path $DriverDir) { Remove-Item -Recurse -Force $DriverDir }
    New-Item -ItemType Directory $DriverDir | Out-Null
    Copy-Item -Recurse (Join-Path $DriverSrc 'About'), (Join-Path $DriverSrc '1.7') $DriverDir

    $mode = if ($Headless) { '-Headless' } else { '-NoWindow' }
    $argLine = "-savedatafolder=$Data $mode -NoCrashDialog -tdscript=$Script -tdout=$Out"
    if ($QuickTest) { $argLine += ' -quicktest' }
    "save: $saveInfo`r`nargs: $argLine" | Out-File (Join-Path $Out 'run-info.txt') -Encoding utf8

    $sw = [Diagnostics.Stopwatch]::StartNew()
    $proc = Start-Process (Join-Path $Game 'RimWorld.exe') -ArgumentList $argLine -WorkingDirectory $Game -PassThru `
        -RedirectStandardOutput (Join-Path $Out 'stdout.txt') -RedirectStandardError (Join-Path $Out 'stderr.txt')
    $null = $proc.Handle
    $maxPeak = -1.0
    $killed = $false
    while (-not $proc.HasExited) {
        $peak = [AudioPeak]::Of($proc.Id)
        if ($peak -gt $maxPeak) { $maxPeak = $peak }
        if ($sw.Elapsed.TotalMinutes -gt $TimeoutMin) { $proc.Kill(); $killed = $true; break }
        Start-Sleep -Milliseconds 250
    }
    $proc.WaitForExit()
    $audio = if ($maxPeak -lt 0) { 'no audio session' } elseif ($maxPeak -lt 0.0001) { "silent (peak $maxPeak)" } else { "AUDIBLE (peak $maxPeak)" }
    @("exit $($proc.ExitCode) after $([int]$sw.Elapsed.TotalSeconds) s$(if ($killed) { ' (killed: timeout)' })", "audio: $audio") |
        Out-File (Join-Path $Out 'run-info.txt') -Append -Encoding utf8
    $instLog = Join-Path $User 'Logs\Player.log'
    if (Test-Path $instLog) { Copy-Item $instLog (Join-Path $Out 'Player.log') }
}
finally {
    if (Test-Path $DriverDir) { Remove-Item -Recurse -Force $DriverDir }
    if ($restoreLogs) {
        foreach ($f in 'Player.log', 'Player-prev.log') {
            $b = Join-Path $logBackup $f
            if (Test-Path $b) { Copy-Item $b (Join-Path $User "Logs\$f") -Force }
        }
    }
    if (-not $KeepData -and (Test-Path $Data)) { Remove-Item -Recurse -Force $Data }
    Remove-Item -Recurse -Force $logBackup -ErrorAction SilentlyContinue
    Remove-Item $Lock -Force -ErrorAction SilentlyContinue
}

Write-Output "out: $Out"
Get-Content (Join-Path $Out 'run-info.txt')
$driverLog = Join-Path $Out 'driver-log.txt'
if (Test-Path $driverLog) { Get-Content $driverLog } else { Write-Output 'driver-log.txt missing: the driver never started (check stdout.txt)' }
$errors = Select-String -Path (Join-Path $Out 'stdout.txt') -Pattern '^\S+\s+ERROR' -ErrorAction SilentlyContinue
Write-Output "ERROR lines in game log: $(@($errors).Count) (stdout.txt)"

# Exit code follows the script result (robocopy's own codes would otherwise leak out as 1).
$ok = (Test-Path $driverLog) -and (Select-String -Path $driverLog -Pattern 'RESULT: OK' -Quiet)
if ($ok) { exit 0 } else { exit 1 }
