<#
.SYNOPSIS
    Installs the VirtIO drivers and the QEMU guest agent inside a Windows guest
    running under QEMU/KVM (Proxmox VE, libvirt, ...).

.DESCRIPTION
    This script is meant to be run INSIDE the Windows virtual machine, from an
    elevated (Administrator) PowerShell session, after the virtio-win ISO has
    been attached to the VM as a CD-ROM (the companion Proxmox script
    proxmox/proxmox-virtio-win.sh does that for you).

    It performs these steps, all of them idempotent (safe to run twice):

      1. Locates the virtio-win media: a CD-ROM drive whose volume label starts
         with "virtio-win", or an ISO file given with -IsoPath (mounted
         temporarily).
      2. Detects the Windows flavour (client/server, build number, CPU
         architecture) to choose the matching driver folder on the ISO, e.g.
         "2k25\amd64" for Windows Server 2025 or "w11\amd64" for Windows 11.
      3. Stages the VirtIO drivers in the Windows driver store with
         "pnputil /add-driver <inf> /install". The storage drivers (vioscsi,
         viostor) are staged FIRST and EXPLICITLY, because they are the ones
         that must be available before the disk bus is changed.
      4. Runs the official "virtio-win-guest-tools.exe" installer, which
         installs the remaining drivers AND the QEMU guest agent (QEMU-GA)
         service. If the .exe is missing, falls back to the .msi package.
      5. Verifies the result (staged drivers, guest agent service) and prints
         a summary table. The exit code is 0 only if everything required is OK.

    Nothing here changes the virtual hardware: switching the network card, the
    display adapter or the disk to VirtIO is done afterwards from the Proxmox
    host with "proxmox-virtio-win.sh finalize".

    A transcript of the whole run is written to
    %ProgramData%\virtio-win-install\ (see -LogPath).

.PARAMETER IsoDriveLetter
    Drive letter (with or without colon) of the CD-ROM that holds the
    virtio-win media. Auto-detected from the volume label when omitted.

.PARAMETER IsoPath
    Path of a virtio-win ISO file to mount, used when no virtio-win CD-ROM is
    found. The image is dismounted again at the end of the script.

.PARAMETER Drivers
    Names of the driver folders (at the root of the ISO) to stage. The default
    covers storage, network, memory ballooning, serial/RNG/input/GPU and the
    pvpanic/fwcfg helpers. Folders absent from the ISO are skipped.

.PARAMETER SkipGuestTools
    Only stage drivers with pnputil; do not run virtio-win-guest-tools.exe
    (so the QEMU guest agent is NOT installed).

.PARAMETER SkipDriverStaging
    Only run virtio-win-guest-tools.exe; do not stage drivers explicitly.

.PARAMETER TimeoutMinutes
    Maximum time to wait for the guest-tools installer (default 15).

.PARAMETER LogPath
    Transcript file. Defaults to a timestamped file under
    %ProgramData%\virtio-win-install.

.EXAMPLE
    # From an elevated prompt (see README.md for the execution policy note):
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install-VirtioWin.ps1

.EXAMPLE
    # Install from an ISO copied into the guest instead of an attached CD-ROM:
    .\Install-VirtioWin.ps1 -IsoPath C:\Temp\virtio-win-0.1.302.iso

.EXAMPLE
    # Stage only the storage and network drivers, skip the guest agent:
    .\Install-VirtioWin.ps1 -Drivers vioscsi,viostor,NetKVM -SkipGuestTools

.NOTES
    Tested on Windows Server 2025. Requires Windows PowerShell 5.1 or later and
    administrative rights. License: MIT.
    Reboot: a reboot is recommended (not forced) after the first installation.
#>

#Requires -Version 5.1
#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [string]   $IsoDriveLetter,
    [string]   $IsoPath,
    [string[]] $Drivers = @('vioscsi', 'viostor', 'NetKVM', 'Balloon', 'vioserial',
                            'viorng', 'vioinput', 'viogpudo', 'pvpanic', 'fwcfg'),
    [switch]   $SkipGuestTools,
    [switch]   $SkipDriverStaging,
    [int]      $TimeoutMinutes = 15,
    [string]   $LogPath = (Join-Path $env:ProgramData ("virtio-win-install\install-{0:yyyyMMdd-HHmmss}.log" -f (Get-Date)))
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# -----------------------------------------------------------------------------
# Logging
# -----------------------------------------------------------------------------

$null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $LogPath)
Start-Transcript -Path $LogPath -Force | Out-Null

function Write-Step { param([string]$Message) Write-Host "[STEP] $Message" -ForegroundColor Cyan }
function Write-Info { param([string]$Message) Write-Host "[INFO] $Message" }
function Write-Warn { param([string]$Message) Write-Host "[WARN] $Message" -ForegroundColor Yellow }

# Collected problems; the script keeps going where reasonable and reports at the
# end, so one missing optional driver does not hide the rest of the results.
$script:Problems = New-Object System.Collections.Generic.List[string]
$script:MountedImage = $null

# -----------------------------------------------------------------------------
# Helper: locate the virtio-win media
# -----------------------------------------------------------------------------

function Get-VirtioDriveRoot {
    <#
    Returns the root path (e.g. "D:\") of the virtio-win media.
    Order of preference: explicit -IsoDriveLetter, CD-ROM labelled virtio-win*,
    then mounting -IsoPath.
    #>
    if ($IsoDriveLetter) {
        $letter = $IsoDriveLetter.TrimEnd(':')
        $root = "${letter}:\"
        if (-not (Test-Path $root)) { throw "Drive $root does not exist." }
        return $root
    }

    $volume = Get-Volume |
        Where-Object { $_.DriveType -eq 'CD-ROM' -and $_.FileSystemLabel -like 'virtio-win*' -and $_.DriveLetter } |
        Sort-Object FileSystemLabel -Descending |      # newest version label first
        Select-Object -First 1
    if ($volume) { return "$($volume.DriveLetter):\" }

    if ($IsoPath) {
        if (-not (Test-Path $IsoPath)) { throw "ISO file not found: $IsoPath" }
        Write-Info "No virtio-win CD-ROM found; mounting $IsoPath"
        $script:MountedImage = $IsoPath
        $image = Mount-DiskImage -ImagePath $IsoPath -PassThru
        $letter = ($image | Get-Volume).DriveLetter
        return "${letter}:\"
    }

    throw "virtio-win media not found. Attach the ISO as a CD-ROM, or pass -IsoDriveLetter / -IsoPath."
}

# -----------------------------------------------------------------------------
# Helper: choose the driver sub-folder matching this Windows version
# -----------------------------------------------------------------------------

function Get-VirtioOsFolder {
    <#
    The ISO stores each driver per Windows release: w7, w8, w8.1, w10, w11 for
    clients and 2k8R2, 2k12, 2k12R2, 2k16, 2k19, 2k22, 2k25 for servers.
    Build numbers: 7601 / 9200 / 9600 / 10240+ (10, 14393 = Server 2016,
    17763 = 2019, 20348 = 2022, 22000+ = 11, 26100+ = Server 2025).
    #>
    $os     = Get-CimInstance Win32_OperatingSystem
    $build  = [int]$os.BuildNumber
    $server = ($os.ProductType -ne 1)       # 1 = workstation, 2/3 = domain controller/server

    if ($server) {
        if     ($build -ge 26100) { return '2k25'   }
        elseif ($build -ge 20348) { return '2k22'   }
        elseif ($build -ge 17763) { return '2k19'   }
        elseif ($build -ge 14393) { return '2k16'   }
        elseif ($build -ge 9600)  { return '2k12R2' }
        elseif ($build -ge 9200)  { return '2k12'   }
        else                      { return '2k8R2'  }
    }
    else {
        if     ($build -ge 22000) { return 'w11'  }
        elseif ($build -ge 10240) { return 'w10'  }
        elseif ($build -ge 9600)  { return 'w8.1' }
        elseif ($build -ge 9200)  { return 'w8'   }
        else                      { return 'w7'   }
    }
}

function Get-VirtioArchFolder {
    # Folder names used by the ISO for the CPU architecture.
    switch ($env:PROCESSOR_ARCHITECTURE) {
        'AMD64' { return 'amd64' }
        'ARM64' { return 'ARM64' }
        default { return 'x86'   }
    }
}

# -----------------------------------------------------------------------------
# Helper: stage one driver with pnputil
# -----------------------------------------------------------------------------

function Add-VirtioDriver {
    param(
        [Parameter(Mandatory)] [string] $Root,       # drive root of the ISO
        [Parameter(Mandatory)] [string] $Name,       # driver folder, e.g. vioscsi
        [Parameter(Mandatory)] [string] $OsFolder,   # e.g. 2k25
        [Parameter(Mandatory)] [string] $Arch        # e.g. amd64
    )

    $dir = Join-Path $Root "$Name\$OsFolder\$Arch"
    if (-not (Test-Path $dir)) {
        Write-Warn "${Name}: no driver for ${OsFolder}\${Arch} on the media; skipped."
        return
    }
    $infs = Get-ChildItem -Path $dir -Filter '*.inf' -File
    if (-not $infs) { Write-Warn "${Name}: no .inf file in ${dir}; skipped."; return }

    foreach ($inf in $infs) {
        Write-Info "Staging $Name ($OsFolder\$Arch) : $($inf.Name)"
        # /install also installs the driver on matching present devices.
        # pnputil exit codes treated as success:
        #   0    driver added (and installed on matching devices);
        #   3010 success, a reboot is required;
        #   259  ERROR_NO_MORE_ITEMS: the driver package is now in the driver
        #        store but no present device matches it yet (for example the
        #        VirtIO NIC does not exist while the VM still uses an e1000e).
        #        This is expected and is what we want: the driver will be used
        #        as soon as the matching virtual hardware appears.
        $output = & pnputil.exe /add-driver $inf.FullName /install 2>&1
        $code = $LASTEXITCODE
        $output | ForEach-Object { Write-Verbose $_ }
        if ($code -eq 259) {
            Write-Verbose "$($inf.Name): staged, no matching device present yet."
        }
        elseif ($code -ne 0 -and $code -ne 3010) {
            $script:Problems.Add("pnputil failed for $($inf.FullName) (exit code $code)")
            Write-Warn "pnputil exit code $code for $($inf.Name)"
        }
    }
}

# -----------------------------------------------------------------------------
# Helper: run the official guest-tools bundle
# -----------------------------------------------------------------------------

function Install-GuestTools {
    param([Parameter(Mandatory)] [string] $Root)

    $exe = Join-Path $Root 'virtio-win-guest-tools.exe'
    $msi = Join-Path $Root 'virtio-win-gt-x64.msi'

    if (Test-Path $exe) {
        # /quiet : no UI;  /norestart : never reboot behind the user's back.
        $arguments = '/install /quiet /norestart'
        Write-Info "Running $exe $arguments (timeout $TimeoutMinutes min)"
        $proc = Start-Process -FilePath $exe -ArgumentList $arguments -PassThru -WindowStyle Hidden
    }
    elseif (Test-Path $msi) {
        Write-Warn 'virtio-win-guest-tools.exe not found; falling back to the MSI package.'
        $arguments = "/i `"$msi`" /qn /norestart ADDLOCAL=ALL"
        $proc = Start-Process -FilePath msiexec.exe -ArgumentList $arguments -PassThru -WindowStyle Hidden
    }
    else {
        $script:Problems.Add('Neither virtio-win-guest-tools.exe nor virtio-win-gt-x64.msi found on the media.')
        return
    }

    if (-not $proc.WaitForExit($TimeoutMinutes * 60 * 1000)) {
        try { $proc.Kill() } catch { }
        $script:Problems.Add("Guest tools installer timed out after $TimeoutMinutes minutes.")
        return
    }
    # 0 = success, 3010 = success but reboot required, 1638 = newer version already installed.
    if (@(0, 3010, 1638) -contains $proc.ExitCode) {
        Write-Info "Guest tools installer finished (exit code $($proc.ExitCode))."
    }
    else {
        $script:Problems.Add("Guest tools installer failed (exit code $($proc.ExitCode)).")
    }
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

try {
    Write-Step 'Locating the virtio-win media'
    $root = Get-VirtioDriveRoot
    $label = (Get-Volume -DriveLetter $root.Substring(0, 1) -ErrorAction SilentlyContinue).FileSystemLabel
    Write-Info "Media: $root ($label)"

    $osFolder = Get-VirtioOsFolder
    $arch     = Get-VirtioArchFolder
    Write-Info "Detected driver folder: $osFolder\$arch"

    if (-not $SkipDriverStaging) {
        Write-Step 'Staging drivers (storage first)'
        # Storage drivers first and unconditionally: without them the disk
        # bus cannot be switched to VirtIO later.
        $ordered = @('vioscsi', 'viostor') + ($Drivers | Where-Object { $_ -notin @('vioscsi', 'viostor') })
        foreach ($name in ($ordered | Select-Object -Unique)) {
            Add-VirtioDriver -Root $root -Name $name -OsFolder $osFolder -Arch $arch
        }
    }

    if (-not $SkipGuestTools) {
        Write-Step 'Installing VirtIO guest tools and the QEMU guest agent'
        Install-GuestTools -Root $root
    }

    # -------------------------------------------------------------------------
    # Verification
    # -------------------------------------------------------------------------
    Write-Step 'Verifying'
    $staged = (& pnputil.exe /enum-drivers 2>&1) -join "`n"
    $checks = @()
    foreach ($inf in @('vioscsi.inf', 'viostor.inf', 'netkvm.inf')) {
        $ok = $staged -match [regex]::Escape($inf)
        $checks += [pscustomobject]@{ Item = "driver $inf"; Status = $(if ($ok) { 'OK' } else { 'MISSING' }) }
        if (-not $ok -and -not $SkipDriverStaging) { $script:Problems.Add("Driver $inf is not in the driver store.") }
    }
    if (-not $SkipGuestTools) {
        $svc = Get-Service -Name 'QEMU-GA' -ErrorAction SilentlyContinue
        $status = if ($svc) { [string]$svc.Status } else { 'NOT INSTALLED' }
        $checks += [pscustomobject]@{ Item = 'service QEMU-GA (guest agent)'; Status = $status }
        if (-not $svc) { $script:Problems.Add('QEMU-GA service is not installed.') }
        elseif ($svc.Status -ne 'Running') {
            # The agent starts when the virtio-serial device is present; it is
            # normal for it to be stopped until the VM has agent=1 and rebooted.
            Write-Warn 'QEMU-GA is installed but not running (needs agent=1 on the host and possibly a reboot).'
        }
    }
    $checks | Format-Table -AutoSize | Out-String | Write-Host

    if ($script:Problems.Count -gt 0) {
        Write-Host '[FAIL] Problems detected:' -ForegroundColor Red
        $script:Problems | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
        $exitCode = 1
    }
    else {
        Write-Host '[ OK ] VirtIO drivers and guest agent are installed.' -ForegroundColor Green
        Write-Host '       A reboot is recommended. Then run "proxmox-virtio-win.sh finalize" on the host.'
        $exitCode = 0
    }
    Write-Info "Log: $LogPath"
}
catch {
    Write-Host "[FAIL] $($_.Exception.Message)" -ForegroundColor Red
    $exitCode = 1
}
finally {
    if ($script:MountedImage) {
        Dismount-DiskImage -ImagePath $script:MountedImage -ErrorAction SilentlyContinue | Out-Null
    }
    Stop-Transcript | Out-Null
}

exit $exitCode
