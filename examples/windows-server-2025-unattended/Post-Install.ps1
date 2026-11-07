<#
.SYNOPSIS
    First-boot configuration run from SetupComplete.cmd (as SYSTEM).

.DESCRIPTION
    1. Installs the VirtIO drivers and the QEMU guest agent with Install-VirtioWin.ps1
       (the virtio-win CD-ROM must still be attached to the VM).
    2. Enables Remote Desktop, with a firewall rule restricted to the local subnet and
       the Tailscale address ranges (not open to the Internet).
    3. Installs the Containers and Hyper-V Windows features (needed for Windows
       containers with Hyper-V isolation) and reboots.
    4. After that reboot, a one-shot scheduled task (Install-Docker.ps1) installs
       Docker CE (Microsoft's helper script) and removes itself.

    Logs: C:\Windows\Temp\post-install.log
#>
$ErrorActionPreference = 'Continue'
Start-Transcript -Path 'C:\Windows\Temp\post-install.log' -Force | Out-Null

Write-Host '[1/4] VirtIO drivers and guest agent'
& "$PSScriptRoot\Install-VirtioWin.ps1" -LogPath 'C:\Windows\Temp\virtio-install.log'

Write-Host '[2/4] Remote Desktop'
Set-ItemProperty 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections -Value 0
New-NetFirewallRule -DisplayName 'RDP from local subnet and Tailscale' -Direction Inbound -Action Allow `
    -Protocol TCP -LocalPort 3389 -Profile Any -RemoteAddress 'LocalSubnet', '100.64.0.0/10', 'fd7a:115c:a1e0::/48' | Out-Null

Write-Host '[3/4] Containers and Hyper-V features'
Install-WindowsFeature -Name Containers, Hyper-V -IncludeManagementTools

Write-Host '[4/4] Docker CE after the reboot (one-shot scheduled task)'
$dockerScript = 'C:\Windows\Setup\Scripts\Install-Docker.ps1'
if (Test-Path $dockerScript) {
    $action  = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument "-NoProfile -ExecutionPolicy Bypass -File $dockerScript"
    Register-ScheduledTask -TaskName 'Install-Docker' -Action $action `
        -Trigger (New-ScheduledTaskTrigger -AtStartup) `
        -User 'SYSTEM' -RunLevel Highest -Force | Out-Null
}

Stop-Transcript | Out-Null
shutdown.exe /r /t 20 /c "Post-install: restart to finish the Hyper-V / Containers features"

