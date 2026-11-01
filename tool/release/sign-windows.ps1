param([Parameter(Mandatory=$true)][string]$Target)
$ErrorActionPreference = 'Stop'
if (!$env:WINDOWS_PFX_PATH -or !$env:WINDOWS_PFX_PASSWORD) { throw 'Configure WINDOWS_PFX_PATH and WINDOWS_PFX_PASSWORD securely' }
$password = ConvertTo-SecureString $env:WINDOWS_PFX_PASSWORD -AsPlainText -Force
$certificates = @(Import-PfxCertificate -FilePath $env:WINDOWS_PFX_PATH -CertStoreLocation Cert:\CurrentUser\My -Password $password | Where-Object { $_.HasPrivateKey })
if ($certificates.Count -ne 1) { throw 'PFX must contain exactly one signing private key' }
$certificate = $certificates[0]
try {
    $items = if (Test-Path $Target -PathType Container) {
        Get-ChildItem $Target -Recurse -File | Where-Object { $_.Extension -in '.exe', '.dll' }
    } else { Get-Item $Target }
    foreach ($item in $items) {
        $signature = Set-AuthenticodeSignature -FilePath $item.FullName -Certificate $certificate -HashAlgorithm SHA256 -TimestampServer 'http://timestamp.digicert.com'
        if ($signature.Status -ne 'Valid') { throw "Signature verification failed: $($item.Name)" }
    }
} finally { Remove-Item "Cert:\CurrentUser\My\$($certificate.Thumbprint)" -ErrorAction SilentlyContinue }
