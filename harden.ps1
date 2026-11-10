$ErrorActionPreference = 'Stop'

Set-NetFirewallProfile -Name Public -PolicyStore localhost -LogAllowed True
gpupdate.exe /target:computer /force /wait:60
if ($LASTEXITCODE -ne 0) { throw 'Computer policy refresh failed.' }

$publicProfile = Get-NetFirewallProfile -Name Public -PolicyStore ActiveStore
if ($publicProfile.LogAllowed -ne 'True') {
    throw 'Public firewall logging for allowed connections is disabled.'
}
Write-Output 'CIS lab check passed: Public firewall logs allowed connections.'

$subcategory = '/subcategory:Process Creation'
auditpol.exe /set $subcategory /success:enable
if ($LASTEXITCODE -ne 0) { throw 'Failed to enable Process Creation auditing.' }

$auditState = auditpol.exe /get $subcategory
if ($LASTEXITCODE -ne 0 -or !($auditState -match '^\s*Process Creation\s+Success\b')) {
    throw 'Successful Process Creation auditing was not verified.'
}
$auditState | Write-Output
Write-Output 'HARDENING_CHECKS_PASSED'
