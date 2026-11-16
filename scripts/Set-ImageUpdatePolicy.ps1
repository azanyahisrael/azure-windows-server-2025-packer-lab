#Requires -Version 5.1
$ErrorActionPreference = 'Stop'

$tools = Join-Path $env:ProgramFiles 'CIS Image Build'
$lgpo = Join-Path $tools 'LGPO.exe'
$policy = Join-Path $tools 'WindowsUpdate.txt'
$key = 'SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'

# Apply the lab's notify-for-install setting through Local Group Policy.
try {
    @('Computer', $key, 'NoAutoUpdate', 'DWORD:0', '',
      'Computer', $key, 'AUOptions', 'DWORD:3', '') | Set-Content -LiteralPath $policy -Encoding Unicode
    & $lgpo /t $policy
    if ($LASTEXITCODE -ne 0) { throw 'LGPO could not apply the Windows Update policy.' }
    & gpupdate.exe /target:computer /force /wait:180
    if ($LASTEXITCODE -ne 0) { throw 'Group Policy refresh failed while applying the Windows Update policy.' }

    $actual = Get-ItemProperty -LiteralPath "HKLM:\$key"
    if ($actual.AUOptions -ne 3 -or $actual.NoAutoUpdate -ne 0) {
        throw 'Windows Update policy did not match immediately after Group Policy refresh.'
    }
    Write-Output 'Windows Update notify-for-install policy applied.'
} finally {
    if (Test-Path -LiteralPath $policy -PathType Leaf) { Remove-Item -LiteralPath $policy -Force }
}
