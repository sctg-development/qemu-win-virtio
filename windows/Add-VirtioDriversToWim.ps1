<#
.SYNOPSIS
    Injects the VirtIO drivers into the boot.wim and install.wim files of a Windows
    installation medium, so the resulting ISO installs on VirtIO hardware out of the box.

.DESCRIPTION
    Run this on a Windows machine (physical or virtual) as Administrator. It needs the
    DISM PowerShell module (built into Windows Server and Windows 10/11) and the
    virtio-win ISO mounted or attached (any drive letter, see -DriverRoot).

    For every selected image of the given WIM files the script:
      1. mounts the image read/write in a scratch directory,
      2. adds all drivers found in <DriverRoot>\<driver>\<OsFolder>\<Arch>
         (vioscsi, viostor, NetKVM, Balloon, vioserial, viorng, vioinput, viogpudo,
         pvpanic, fwcfg, ...) with Add-WindowsDriver,
      3. unmounts and commits the image.

    Adding the drivers to boot.wim (WinPE, both images) lets Windows Setup see a VirtIO
    SCSI/block disk and use a VirtIO network card. Adding them to install.wim puts the
    drivers in the driver store of the installed system, so it can boot from the VirtIO
    disk without any extra step.

    The script only edits the WIM files you point it at; building the final ISO
    (genisoimage -udf, oscdimg, ...) is a separate step, see the README.

.PARAMETER DriverRoot
    Root of the virtio-win media, for example 'D:\'.

.PARAMETER BootWim
    Path of boot.wim (optional). Both images (WinPE and Setup) are updated.

.PARAMETER InstallWim
    Path of install.wim (optional).

.PARAMETER InstallIndex
    Indexes of install.wim to update. Default: all of them.

.PARAMETER OsFolder
    Driver folder of the target Windows release on the virtio-win media: w10, w11,
    2k16, 2k19, 2k22 or 2k25. Default: 2k25 (Windows Server 2025).

.PARAMETER Arch
    Architecture folder: amd64 (default), x86 or ARM64.

.PARAMETER MountRoot
    Scratch directory used for mounting (needs a few GB free). Default: C:\wim-mount.

.EXAMPLE
    .\Add-VirtioDriversToWim.ps1 -DriverRoot D:\ -BootWim C:\iso\boot.wim -InstallWim C:\iso\install.wim

.NOTES
    License: MIT. If a previous run was interrupted, clean stale mounts first with
    "Dism /Cleanup-Wim" before running again.
#>

#Requires -Version 5.1
#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]   $DriverRoot,
    [string]                          $BootWim,
    [string]                          $InstallWim,
    [int[]]                           $InstallIndex,
    [string]                          $OsFolder  = '2k25',
    [ValidateSet('amd64', 'x86', 'ARM64')] [string] $Arch = 'amd64',
    [string]                          $MountRoot = 'C:\wim-mount'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Step { param([string]$Message) Write-Host "[STEP] $Message" -ForegroundColor Cyan }
function Write-Info { param([string]$Message) Write-Host "[INFO] $Message" }

if (-not $BootWim -and -not $InstallWim) { throw 'Give at least -BootWim or -InstallWim.' }

# -----------------------------------------------------------------------------
# Collect the driver directories (one per VirtIO driver) for the target OS
# -----------------------------------------------------------------------------
$driverDirs = Get-ChildItem -Path $DriverRoot -Directory |
    ForEach-Object { Join-Path $_.FullName "$OsFolder\$Arch" } |
    Where-Object { Test-Path $_ }
if (-not $driverDirs) { throw "No driver folder '*\$OsFolder\$Arch' found under $DriverRoot." }
Write-Info ("Driver folders: " + (($driverDirs | ForEach-Object { Split-Path (Split-Path (Split-Path $_)) -Leaf }) -join ', '))
Write-Info ("{0} driver folders will be injected." -f @($driverDirs).Count)

# -----------------------------------------------------------------------------
# Inject into one image of one WIM file
# -----------------------------------------------------------------------------
function Add-DriversToImage {
    param([string]$WimPath, [int]$Index)

    $mount = Join-Path $MountRoot ([IO.Path]::GetFileNameWithoutExtension($WimPath) + "-$Index")
    $null = New-Item -ItemType Directory -Force -Path $mount
    $saved = $false
    Write-Step "$([IO.Path]::GetFileName($WimPath)) index ${Index}: mounting"
    Mount-WindowsImage -ImagePath $WimPath -Index $Index -Path $mount | Out-Null
    try {
        foreach ($dir in $driverDirs) {
            Write-Info ("  adding " + (Split-Path (Split-Path (Split-Path $dir)) -Leaf))
            # -ForceUnsigned is deliberately NOT used: the VirtIO drivers are WHQL signed.
            # Some packages (e.g. smbus, sriov) are refused by WinPE with "The request is
            # not supported"; that is harmless, so warn and go on with the next driver.
            try   { Add-WindowsDriver -Path $mount -Driver $dir -Recurse | Out-Null }
            catch { Write-Warning ("  skipped " + (Split-Path (Split-Path (Split-Path $dir)) -Leaf) + ": " + $_.Exception.Message) }
        }
        Write-Step "$([IO.Path]::GetFileName($WimPath)) index ${Index}: saving"
        Dismount-WindowsImage -Path $mount -Save | Out-Null
        $saved = $true
    }
    finally {
        # On any failure, discard the changes so the WIM is never left mounted.
        if (-not $saved) { Dismount-WindowsImage -Path $mount -Discard -ErrorAction SilentlyContinue | Out-Null }
        Remove-Item $mount -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if ($BootWim) {
    foreach ($img in (Get-WindowsImage -ImagePath $BootWim)) { Add-DriversToImage -WimPath $BootWim -Index $img.ImageIndex }
}
if ($InstallWim) {
    $indexes = if ($InstallIndex) { $InstallIndex } else { (Get-WindowsImage -ImagePath $InstallWim).ImageIndex }
    foreach ($i in $indexes) { Add-DriversToImage -WimPath $InstallWim -Index $i }
}

Write-Host '[ OK ] Drivers injected.' -ForegroundColor Green
