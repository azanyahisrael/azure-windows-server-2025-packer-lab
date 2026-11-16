#Requires -Version 5.1
$ErrorActionPreference = 'Stop'

# This directory inherits Program Files permissions. Packer runs this step as SYSTEM.
$tools = Join-Path $env:ProgramFiles 'CIS Image Build'
New-Item -ItemType Directory -Path $tools -Force | Out-Null
$zip = Join-Path $tools 'LGPO.zip'
$lgpo = Join-Path $tools 'LGPO.exe'
$url = 'https://download.microsoft.com/download/8/5/c/85c25433-a1b0-4ffa-9429-7e023e7da8d8/LGPO.zip'
$sha256 = 'CB7159D134A0A1E7B1ED2ADA9A3CE8CE8F4DE391D14403D55438AF824247CC55'

try {
    & curl.exe --fail --silent --show-error --location --proto '=https' --proto-redir '=https' --retry 3 --max-time 120 --output $zip $url
    if ($LASTEXITCODE -ne 0) { throw "LGPO download failed with curl exit code $LASTEXITCODE." }
    if ((Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash -ne $sha256) {
        throw 'LGPO.zip did not match the pinned SHA-256. Review the Microsoft download before changing the hash.'
    }

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($zip)
    try {
        $entries = @($archive.Entries | Where-Object Name -eq 'LGPO.exe')
        if ($entries.Count -ne 1) { throw 'Expected exactly one LGPO.exe in the Microsoft ZIP.' }
        [IO.Compression.ZipFileExtensions]::ExtractToFile($entries[0], $lgpo, $true)
    } finally {
        $archive.Dispose()
    }
    $signature = Get-AuthenticodeSignature -LiteralPath $lgpo
    if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch '(^|,\s*)O=Microsoft Corporation(,|$)') {
        throw 'LGPO.exe does not have a valid Microsoft signature.'
    }

    Write-Output 'Verified Microsoft LGPO.'
} finally {
    if (Test-Path -LiteralPath $zip -PathType Leaf) { Remove-Item -LiteralPath $zip -Force }
}
