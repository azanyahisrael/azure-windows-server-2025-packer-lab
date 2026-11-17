# AWS only. Leaves a cleanup task for the first boot of every instance made from the
# AMI, then generalizes this instance with Sysprep so Packer can capture it.
$ErrorActionPreference = 'Stop'

# 1. First-boot cleanup. It removes what only the build needed: the remote admin
# exception, and the WinRM HTTPS listener, certificate and firewall rule that
# aws-winrm-bootstrap.ps1 added.
$folder = Join-Path $env:ProgramData 'ImageCleanup'
New-Item -ItemType Directory -Path $folder -Force | Out-Null
@'
$ErrorActionPreference = 'Continue'
Start-Service -Name WinRM
Remove-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -Name LocalAccountTokenFilterPolicy -ErrorAction SilentlyContinue
Get-ChildItem -Path WSMan:\localhost\Listener | Where-Object { $_.Keys -contains 'Transport=HTTPS' } | Remove-Item -Recurse -Force
Get-ChildItem -Path Cert:\LocalMachine\My | Where-Object FriendlyName -eq 'Packer WinRM' | Remove-Item -Force
Remove-NetFirewallRule -DisplayName 'WinRM HTTPS for Packer' -ErrorAction SilentlyContinue
Unregister-ScheduledTask -TaskName 'ImageFirstBootCleanup' -Confirm:$false
Remove-Item -LiteralPath $PSScriptRoot -Recurse -Force
'@ | Set-Content -LiteralPath (Join-Path $folder 'Cleanup.ps1') -Encoding UTF8

$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$folder\Cleanup.ps1`""
$trigger = New-ScheduledTaskTrigger -AtStartup
$trigger.Delay = 'PT2M' # Give WinRM time to start first.
Register-ScheduledTask -TaskName 'ImageFirstBootCleanup' -Action $action -Trigger $trigger -User 'SYSTEM' -RunLevel Highest -Force | Out-Null

# 2. Reset EC2Launch v2, so a new instance runs its first-boot tasks again,
# including setting a new random Administrator password.
& (Join-Path $env:ProgramFiles 'Amazon\EC2Launch\EC2Launch.exe') reset --clean --block

# 3. Generalize with EC2Launch's answer file. /quit leaves the instance running, so
# Packer, not Windows, stops it before creating the AMI.
$unattend = Join-Path $env:ProgramData 'Amazon\EC2Launch\sysprep\unattend.xml'
& (Join-Path $env:SystemRoot 'System32\Sysprep\Sysprep.exe') /generalize /oobe /quiet /quit /mode:vm "/unattend:$unattend"
while ((Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State').ImageState -ne 'IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE') {
    Start-Sleep -Seconds 10
}
Write-Output 'Sysprep finished. Packer will now stop the instance and create the AMI.'
