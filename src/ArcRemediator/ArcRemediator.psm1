#Requires -Version 5.1

Set-StrictMode -Version 3.0

$script:ModuleRoot = $PSScriptRoot

$privateFiles = @(
    Get-ChildItem -Path (Join-Path $script:ModuleRoot 'Private') -Filter '*.ps1' -File -ErrorAction SilentlyContinue
)
$publicFiles = @(
    Get-ChildItem -Path (Join-Path $script:ModuleRoot 'Public') -Filter '*.ps1' -File -ErrorAction SilentlyContinue
)

foreach ($file in @($privateFiles) + @($publicFiles)) {
    try {
        . $file.FullName
    } catch {
        throw "Failed to dot-source $($file.FullName): $($_.Exception.Message)"
    }
}

if ($publicFiles.Count -gt 0) {
    Export-ModuleMember -Function $publicFiles.BaseName
}
