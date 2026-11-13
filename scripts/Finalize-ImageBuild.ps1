#Requires -Version 5.1
$ErrorActionPreference = 'Stop'

$updateKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
if ((Get-ItemPropertyValue -LiteralPath $updateKey -Name AUOptions) -ne 3 -or
    (Get-ItemPropertyValue -LiteralPath $updateKey -Name NoAutoUpdate) -ne 0) {
    throw 'Expected Windows Update to notify before installing.'
}

$logonKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
if ((Get-ItemPropertyValue -LiteralPath $logonKey -Name InactivityTimeoutSecs) -ne 900) {
    throw 'CIS 2.3.7.3: expected a machine inactivity limit of 900 seconds.'
}
$winrmKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WinRM\Service'
if ((Get-ItemPropertyValue -LiteralPath $winrmKey -Name AllowBasic) -ne 0) {
    throw 'CIS 18.10.90.2.1: expected WinRM Basic authentication to be disabled.'
}

$lgpo = Join-Path $env:ProgramFiles 'CIS Image Build\LGPO.exe'
if (Test-Path -LiteralPath $lgpo -PathType Leaf) { Remove-Item -LiteralPath $lgpo -Force }
Write-Output 'HARDENING_CHECKS_PASSED'
