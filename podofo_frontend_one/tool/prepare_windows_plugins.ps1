# Optional fallback for Windows accounts without symbolic-link privileges.
# Run after `flutter pub get` has written .flutter-plugins-dependencies.
# This creates only project-local directory junctions; it changes no OS settings.
$ErrorActionPreference = 'Stop'
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$metadataPath = Join-Path $projectRoot '.flutter-plugins-dependencies'
if (!(Test-Path -LiteralPath $metadataPath)) {
    throw 'Run flutter pub get first to generate plugin metadata.'
}
$metadata = Get-Content -Raw -LiteralPath $metadataPath | ConvertFrom-Json
foreach ($platformName in @('windows', 'linux')) {
    $junctionRoot = Join-Path $projectRoot "$platformName/flutter/ephemeral/.plugin_symlinks"
    New-Item -ItemType Directory -Path $junctionRoot -Force | Out-Null
    foreach ($plugin in $metadata.plugins.$platformName) {
        if ($plugin.name -notmatch '^[a-z0-9_]+$') { throw 'Invalid plugin name.' }
        $junctionPath = Join-Path $junctionRoot $plugin.name
        $targetPath = [IO.Path]::GetFullPath($plugin.path)
        if (!(Test-Path -LiteralPath $targetPath -PathType Container)) {
            throw "Plugin package is missing: $($plugin.name)"
        }
        if (Test-Path -LiteralPath $junctionPath) {
            $existing = Get-Item -LiteralPath $junctionPath
            if ($existing.LinkType -ne 'Junction') { throw "Expected a junction: $junctionPath" }
            if ([IO.Path]::GetFullPath($existing.Target[0]).TrimEnd('\') -ne $targetPath.TrimEnd('\')) {
                # Nonrecursive Delete removes only the verified junction itself.
                [IO.Directory]::Delete($junctionPath)
            }
        }
        if (!(Test-Path -LiteralPath $junctionPath)) {
            New-Item -ItemType Junction -Path $junctionPath -Target $targetPath | Out-Null
        }
    }
}
Write-Output 'Plugin junctions are ready. Run flutter pub get again.'
