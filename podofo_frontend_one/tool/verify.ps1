param(
    [string]$Flutter = 'flutter',
    [string]$Dart = 'dart'
)
$ErrorActionPreference = 'Stop'
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
Push-Location $projectRoot
try {
    & $Dart format --output=none --set-exit-if-changed lib test
    if ($LASTEXITCODE -ne 0) { throw 'Formatting differs' }
    $generated = @('lib/objectbox-model.json', 'lib/objectbox.g.dart')
    $before = @{}
    foreach ($file in $generated) {
        $before[$file] = [IO.File]::ReadAllText((Join-Path $projectRoot $file)).Replace("`r`n", "`n")
    }
    & $Dart run build_runner build
    if ($LASTEXITCODE -ne 0) { throw 'Generation failed' }
    & $Dart format lib/objectbox.g.dart
    if ($LASTEXITCODE -ne 0) { throw 'Generated code formatting failed' }
    foreach ($file in $generated) {
        $after = [IO.File]::ReadAllText((Join-Path $projectRoot $file)).Replace("`r`n", "`n")
        if ($before[$file] -cne $after) { throw "Generated file was stale: $file" }
    }
    & $Flutter analyze --no-pub
    if ($LASTEXITCODE -ne 0) { throw 'Analysis failed' }
    # Windows PowerShell treats native stderr as ErrorRecords when redirected.
    # CMake emits development warnings there even on successful builds.
    try {
        $ErrorActionPreference = 'Continue'
        & $Flutter build windows --release --no-pub
        $buildExitCode = $LASTEXITCODE
    } finally { $ErrorActionPreference = 'Stop' }
    if ($buildExitCode -ne 0) { throw 'Windows release build failed' }
    $originalPath = $env:PATH
    try {
        # Tests exercise the same ObjectBox DLL distributed in the application.
        $env:PATH = (Join-Path $projectRoot 'build/windows/x64/runner/Release') + ';' + $env:PATH
        & $Flutter test --no-pub --reporter expanded --timeout 60s
        if ($LASTEXITCODE -ne 0) { throw 'Regression tests failed' }
    } finally { $env:PATH = $originalPath }
} finally { Pop-Location }
