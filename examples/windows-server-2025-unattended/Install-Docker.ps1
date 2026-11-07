<#
.SYNOPSIS
    One-shot task (started at boot by the 'Install-Docker' scheduled task): installs
    Docker CE for Windows containers with Microsoft's helper script, then removes
    the task. Log: C:\Windows\Temp\install-docker.log
#>
$ErrorActionPreference = 'Continue'
Start-Transcript -Path 'C:\Windows\Temp\install-docker.log' -Force | Out-Null
try {
    $url = 'https://raw.githubusercontent.com/microsoft/Windows-Containers/Main/helpful_tools/Install-DockerCE/install-docker-ce.ps1'
    Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile 'C:\Windows\Temp\install-docker-ce.ps1'
    & 'C:\Windows\Temp\install-docker-ce.ps1'
    # The helper may reboot the machine itself; the task only goes away once docker answers.
    if (Get-Command docker -ErrorAction SilentlyContinue) {
        docker version
        Unregister-ScheduledTask -TaskName 'Install-Docker' -Confirm:$false
    }
} finally {
    Stop-Transcript | Out-Null
}
