$ErrorActionPreference = 'Stop'

# Run Command uses the Azure VM Agent, so it survives removal of the WinRM listener.
foreach ($listener in (Get-ChildItem WSMan:\localhost\Listener | Where-Object { $_.Keys -contains 'Transport=HTTPS' })) {
    $thumbprint = (Get-Item -LiteralPath (Join-Path $listener.PSPath 'CertificateThumbprint')).Value
    Remove-Item -LiteralPath $listener.PSPath -Recurse
    if ($thumbprint -match '^[A-Fa-f0-9]{40}$') {
        $certificate = "Cert:\LocalMachine\My\$thumbprint"
        if (Test-Path -LiteralPath $certificate) { Remove-Item -LiteralPath $certificate -DeleteKey }
    }
}

$buildUser = Get-LocalUser -Name 'packerbuild' -ErrorAction SilentlyContinue
if ($buildUser) { Remove-LocalUser -InputObject $buildUser }

$cdrom = 'HKLM:\SYSTEM\CurrentControlSet\Services\cdrom'
if ((Get-ItemPropertyValue -LiteralPath $cdrom -Name Start) -eq 4) {
    throw 'Azure generalized provisioning requires the CD-ROM driver.'
}

foreach ($name in 'RdAgent', 'WindowsAzureGuestAgent') {
    $service = Get-Service -Name $name
    $service.WaitForStatus([System.ServiceProcess.ServiceControllerStatus]::Running, [TimeSpan]::FromMinutes(5))
}

$arguments = '/generalize', '/oobe', '/quiet', '/quit', '/mode:vm'
$sysprep = Start-Process "$env:SystemRoot\System32\Sysprep\Sysprep.exe" -ArgumentList $arguments -PassThru
if (!$sysprep.WaitForExit(900000)) { throw 'Sysprep exceeded 15 minutes.' }
if ($sysprep.ExitCode -ne 0) { throw "Sysprep failed ($($sysprep.ExitCode))." }

$stateKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State'
if ((Get-ItemPropertyValue -LiteralPath $stateKey -Name ImageState) -ne 'IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE') {
    throw 'Windows did not reach the generalized image state.'
}
Write-Output 'IMAGE_GENERALIZED'
