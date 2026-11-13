$ErrorActionPreference = 'Stop'
$system = Get-CimInstance Win32_ComputerSystem
$os = Get-CimInstance Win32_OperatingSystem
if ($system.PartOfDomain -or $os.ProductType -ne 3 -or $os.BuildNumber -ne '26100' -or -not [Environment]::Is64BitProcess) {
    throw 'Expected a 64-bit Windows Server 2025 workgroup VM.'
}

$buffer = [IO.MemoryStream]::new([Convert]::FromBase64String($catalogData))
$zip = [IO.Compression.GZipStream]::new($buffer, [IO.Compression.CompressionMode]::Decompress)
$reader = [IO.StreamReader]::new($zip, [Text.Encoding]::UTF8)
try { $catalog = $reader.ReadToEnd() | ConvertFrom-Json }
finally { $reader.Dispose() }

$scratch = Join-Path $env:TEMP ([guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $scratch | Out-Null
try {
    $template = Join-Path $scratch 'security.inf'
    $audit = Join-Path $scratch 'audit.csv'
    & secedit.exe /export /mergedpolicy /cfg $template /areas SECURITYPOLICY USER_RIGHTS /log (Join-Path $scratch 'secedit.log') /quiet | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Could not export effective security policy.' }
    & auditpol.exe /backup "/file:$audit" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Could not export effective audit policy.' }
    $policy = Get-SecurityTemplate -Path $template
    if (-not $policy.ContainsKey('System Access') -or -not $policy.ContainsKey('Privilege Rights')) {
        throw 'The security policy export is incomplete.'
    }
    $auditRows = @(Import-Csv -LiteralPath $audit)
    $firewall = @{}
    foreach ($state in Get-NetFirewallProfile -PolicyStore ActiveStore -Name Private,Public) {
        $firewall[$state.Name] = $state
    }
    $roles = @{}
    foreach ($feature in Get-WindowsFeature -Name @($catalog.Role | Where-Object { $_ } | Sort-Object -Unique)) {
        $roles[$feature.Name] = $feature.Installed
    }

    $skipped = @($catalog | Where-Object {
        $_.Parameter -or $_.Scope -eq 'User' -or $_.Assessment -eq 'Manual' -or $_.Id -eq '18.10.94.2.2'
    })
    $checks = @($catalog | Where-Object Id -notin $skipped.Id)
    $updateKey = 'SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
    $checks += [pscustomobject]@{ Id='WindowsUpdateException'; Method='Registry'; Registry=@(
        @{ Key=$updateKey; Name='AUOptions'; Type='DWORD'; Value=3 }
        @{ Key=$updateKey; Name='NoAutoUpdate'; Type='DWORD'; Value=0 }
    )}

    $drift = @(foreach ($row in $checks) {
        $valid = $false
        switch ($row.Method) {
            'Registry' {
                $valid = $true
                foreach ($entry in $row.Registry) {
                    if (-not (Test-RegistrySetting -Entry $entry) -or
                        ($row.Id -like '9.*' -and -not (Test-FirewallSetting -Control $row -Settings $firewall -Entry $entry))) {
                        $valid = $false
                    }
                }
                if ($row.Id -eq '18.4.1') {
                    $dependencies = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Services\LanmanWorkstation'
                    $valid = $valid -and 'MRxSmb10' -notin $dependencies.DependOnService
                }
            }
            'Account' {
                $actual = $policy['System Access'][$row.Name]
                $valid = $null -ne $actual -and $actual.Trim('"') -eq [string]$row.Value
            }
            'Rights' {
                $actual = @($policy['Privilege Rights'][$row.Name] -split ',' | ForEach-Object {
                    $identity = $_.Trim()
                    if ($identity -match '^\*?(S-[0-9-]+)$') { $Matches[1] }
                    elseif ($identity) {
                        ([Security.Principal.NTAccount]::new($identity)).Translate(
                            [Security.Principal.SecurityIdentifier]).Value
                    }
                })
                $expected = @($row.Value)
                if ($row.Role) {
                    if (-not $roles.ContainsKey($row.Role)) { throw "Could not determine role $($row.Role)." }
                    if ($roles[$row.Role]) { $expected += $row.RoleSid }
                }
                $valid = @($expected | Where-Object { $_ -notin $actual }).Count -eq 0 -and
                    ($row.Preserve -or @($actual | Where-Object { $_ -notin $expected }).Count -eq 0)
            }
            'Audit' {
                $actual = [int](Get-AuditSystemRow -Rows $auditRows -Guid $row.Name).'Setting Value'
                $expected = [int]$row.Value
                $valid = $actual -eq $expected -or ($row.Preserve -and ($actual -band $expected) -eq $expected)
            }
            default { throw "Unsupported check method $($row.Method)." }
        }
        if (-not $valid) { $row.Id }
    })
    $result = [ordered]@{ checked=$checks.Count; unassessed=$skipped.Count; drift=$drift }
    # Managed Run Command returns the tail of stdout. IDs keep the report within its limit.
    Write-Output ('CIS_DRIFT_RESULT=' + ($result | ConvertTo-Json -Compress))
} finally {
    Remove-Item -LiteralPath $scratch -Recurse -Force
}
