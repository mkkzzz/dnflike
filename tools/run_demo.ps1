param([string]$GodotPath = "", [switch]$Test, [switch]$Capture)
$ErrorActionPreference = "Stop"
$repoRoot = Split-Path $PSScriptRoot -Parent
if (-not $GodotPath) {
    $GodotPath = Join-Path $PSScriptRoot "godot/Godot_v4.7.2-stable_win64_console.exe"
}
if (-not (Test-Path -LiteralPath $GodotPath)) {
    throw "Godot missing. Run tools/setup_godot.ps1, or provide -GodotPath to a Godot 4 executable."
}
$gamePath = Join-Path $repoRoot "game"
$importOutput = & $GodotPath --headless --path $gamePath --editor --import --quit 2>&1
if ($LASTEXITCODE -ne 0 -or ($importOutput -match 'SCRIPT ERROR|ERROR:')) {
    $importOutput | Write-Output
    throw "Godot import failed."
}
if ($Test) {
    $testArgs = @("--headless", "--fixed-fps", "60", "--path", $gamePath, "--quit-after", "5000", "--", "--test")
    if ($Capture) {
        $testArgs = @("--fixed-fps", "60", "--path", $gamePath, "--quit-after", "5000", "--", "--test", "--capture")
    }
    $testOutput = & $GodotPath @testArgs 2>&1
    $engineExit = $LASTEXITCODE
    $testOutput | Write-Output
    if ($engineExit -ne 0 -or ($testOutput -match 'SCRIPT ERROR|ERROR:') -or -not ($testOutput -match '\[DEMO_TEST\] COMPLETE checks=\d+ failures=0')) {
        throw "Combat demo regression checks failed or did not complete."
    }
} elseif ($Capture) {
    & $GodotPath --path $gamePath --fixed-fps 60 -- --capture
} else {
    & $GodotPath --path $gamePath
}
