param(
    [Parameter(Mandatory)][string]$OutputPath,
    [string]$BaselinePath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'Harden-V2.ps1')
)

$ErrorActionPreference = 'Stop'
$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    $BaselinePath, [ref]$tokens, [ref]$errors)
if ($errors) { throw ($errors | Out-String) }

# Read the same catalog the provisioner applies, without running the provisioner.
$catalog = $ast.Find({
    param($node)
    $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
        $node.Left.Extent.Text -eq '$raw'
}, $false)
if (-not $catalog) { throw 'The baseline script has no control catalog.' }
$source = $catalog.Right.Find({
    param($node)
    $node -is [System.Management.Automation.Language.StringConstantExpressionAst]
}, $false).Value
$rows = @($source | ConvertFrom-Json | Where-Object Profile -eq 'L1')
if ($rows.Count -eq 0) { throw 'The baseline script has no Level 1 controls.' }

$functions = foreach ($name in 'Get-SecurityTemplate','Test-RegistrySetting','Get-AuditSystemRow','Test-FirewallSetting') {
    $function = $ast.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
    }, $false)
    if (-not $function) { throw "The baseline script is missing $name." }
    $function.Extent.Text
}

# Keep the inline Azure Run Command payload compact.
$data = $rows | Select-Object Id,Method,Assessment,Scope,Parameter,Name,Value,Registry,Role,RoleSid,Preserve |
    ConvertTo-Json -Compress -Depth 8
$buffer = [IO.MemoryStream]::new()
$zip = [IO.Compression.GZipStream]::new($buffer, [IO.Compression.CompressionLevel]::Optimal, $true)
try {
    $bytes = [Text.Encoding]::UTF8.GetBytes($data)
    $zip.Write($bytes, 0, $bytes.Length)
} finally { $zip.Dispose() }
$encoded = [Convert]::ToBase64String($buffer.ToArray())
$buffer.Dispose()

$payload = @(
    ('$catalogData = ''{0}''' -f $encoded)
    $functions
    Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Test-ImageDrift.ps1') -Raw
) -join [Environment]::NewLine
[IO.File]::WriteAllText($OutputPath, $payload, [Text.UTF8Encoding]::new($false))
