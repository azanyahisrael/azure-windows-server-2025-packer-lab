<powershell>
# EC2 user data: AWS runs this once, at the instance's first boot. It gives Packer a
# WinRM HTTPS listener on port 5986, which Azure sets up by itself but AWS does not.
$ErrorActionPreference = 'Stop'

# Make sure the WinRM service is running.
Set-Service -Name WinRM -StartupType Automatic
Start-Service -Name WinRM

# Self-signed certificate for the listener. Packer accepts it because of winrm_insecure.
$cert = New-SelfSignedCertificate -DnsName $env:COMPUTERNAME -CertStoreLocation Cert:\LocalMachine\My

# HTTPS listener on port 5986, using that certificate.
New-Item -Path WSMan:\localhost\Listener -Transport HTTPS -Address * -CertificateThumbPrint $cert.Thumbprint -Force | Out-Null

# Let port 5986 through Windows Firewall. AWS's security group still limits who can reach it.
New-NetFirewallRule -DisplayName 'WinRM HTTPS for Packer' -Direction Inbound -Protocol TCP -LocalPort 5986 -Action Allow | Out-Null

Restart-Service -Name WinRM
</powershell>
