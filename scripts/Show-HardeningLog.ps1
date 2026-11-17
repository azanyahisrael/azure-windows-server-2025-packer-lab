# Prints what the CIS script did, so the Packer log shows which controls failed and why.
# Packer runs this after hardening, and again if any later build step fails.
$ErrorActionPreference = 'Continue'

$run = Get-ChildItem -Path $env:ProgramData -Directory -Filter 'HardenedV2-*' -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime | Select-Object -Last 1
if (-not $run) {
    Write-Output 'No CIS run folder found, so the hardening script applied no settings.'
} else {
    Write-Output "CIS run folder: $($run.FullName)"
    $failed = @()
    $results = Join-Path $run.FullName 'Results.csv'
    if (Test-Path -LiteralPath $results) {
        $rows = @(Import-Csv -LiteralPath $results)
        Write-Output 'Controls by status:'
        $rows | Group-Object Status | Sort-Object Name | ForEach-Object { '  {0}: {1}' -f $_.Name, $_.Count }
        $failed = @($rows | Where-Object Status -in 'Check required', 'Interrupted', 'Not applied')
        foreach ($row in $failed) {
            Write-Output ('  FAILED {0} [{1}] {2}. {3}' -f $row.Id, $row.Status, $row.Control, $row.Detail)
        }
    }

    # The tool logs only matter when something went wrong.
    $errorLog = Join-Path $run.FullName 'Error.log'
    if ($failed.Count -or (Test-Path -LiteralPath $errorLog)) {
        foreach ($log in Get-ChildItem -LiteralPath $run.FullName -Filter *.log) {
            Write-Output "--- $($log.Name) ---"
            Get-Content -LiteralPath $log.FullName -Tail 40
        }
    }
}

# These decide whether Packer can sign back in over WinRM after the reboot.
$system = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -ErrorAction SilentlyContinue
$lsa = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' -ErrorAction SilentlyContinue
$msv = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa\MSV1_0' -ErrorAction SilentlyContinue
$user = Get-LocalUser -Name 'packerbuild' -ErrorAction SilentlyContinue
Write-Output 'Settings that affect the Packer connection after the reboot:'
Write-Output ('  packerbuild is the built-in Administrator (RID 500): {0}' -f ($null -ne $user -and $user.SID.Value -like '*-500'))
Write-Output ('  FilterAdministratorToken: {0}' -f $system.FilterAdministratorToken)
Write-Output ('  LocalAccountTokenFilterPolicy: {0}' -f $system.LocalAccountTokenFilterPolicy)
Write-Output ('  LmCompatibilityLevel: {0}' -f $lsa.LmCompatibilityLevel)
Write-Output ('  NTLMMinServerSec: {0}' -f $msv.NTLMMinServerSec)
