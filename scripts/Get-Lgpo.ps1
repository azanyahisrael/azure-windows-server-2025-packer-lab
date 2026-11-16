# Downloads Microsoft's LGPO.exe, which the CIS hardening script uses to import policy.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$url = 'https://download.microsoft.com/download/8/5/c/85c25433-a1b0-4ffa-9429-7e023e7da8d8/LGPO.zip'
$sha256 = 'CB7159D134A0A1E7B1ED2ADA9A3CE8CE8F4DE391D14403D55438AF824247CC55'
$zip = Join-Path $env:TEMP 'LGPO.zip'
$unpacked = Join-Path $env:TEMP 'LGPO'

Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing
if ((Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash -ne $sha256) {
    throw 'LGPO.zip did not match the pinned SHA-256.'
}
Expand-Archive -LiteralPath $zip -DestinationPath $unpacked -Force
New-Item -ItemType Directory -Path C:\LGPO -Force | Out-Null
Get-ChildItem -LiteralPath $unpacked -Recurse -Filter LGPO.exe | Copy-Item -Destination C:\LGPO\LGPO.exe
Remove-Item -LiteralPath $zip, $unpacked -Recurse -Force
Write-Output 'LGPO is ready.'
