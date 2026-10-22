param([string]$GodotPath="",[switch]$Test,[switch]$Capture,[switch]$Editor,[switch]$BuildAssets,[string]$LibraryPath="")
$ErrorActionPreference="Stop"
$repoRoot=Split-Path $PSScriptRoot -Parent
$gamePath=Join-Path $repoRoot "game_dnf"
if (-not $GodotPath) {$GodotPath=Join-Path $PSScriptRoot "godot/Godot_v4.7.2-stable_win64_console.exe"}
if (-not (Test-Path -LiteralPath $GodotPath)) {throw "Godot missing; run tools/setup_godot.ps1."}
$versionText="$(& $GodotPath --version 2>$null | Select-Object -First 1)".Trim()
if (-not $versionText.StartsWith("4.7.2.")) {throw "Godot 4.7.2 required; found $versionText"}
if ($BuildAssets) {
    $buildArgs=@((Join-Path $PSScriptRoot "build_dnf_assets.py"))
    if ($LibraryPath) {$buildArgs+=@("--library",$LibraryPath)}
    & python @buildArgs
    if ($LASTEXITCODE -ne 0) {throw "Local DNF resource build failed."}
}
if (-not (Test-Path -LiteralPath (Join-Path $gamePath "assets_local/manifest.json"))) {
    throw "Local assets missing. Use -BuildAssets -LibraryPath <local extraction library>; raw client assets are deliberately excluded from Git."
}
$ErrorActionPreference="Continue"
$importOutput=& $GodotPath --headless --path $gamePath --editor --import --quit 2>&1
$importExit=$LASTEXITCODE
$ErrorActionPreference="Stop"
if ($importExit -ne 0 -or ($importOutput -match 'SCRIPT ERROR|ERROR:')) {
    $importOutput | Write-Output
    throw "New project import failed."
}
if ($Editor) {& $GodotPath --path $gamePath --editor; exit $LASTEXITCODE}
$runArgs=@("--path",$gamePath)
if ($Test) {
    $runArgs+=@("--fixed-fps","60","--quit-after","3500")
    if ($Capture) {$runArgs+=@("--position","-32000,-32000")} else {$runArgs+="--headless"}
    $runArgs+=@("--","--test")
    if ($Capture) {$runArgs+="--capture"}
} elseif ($Capture) {$runArgs+=@("--","--capture")}
$ErrorActionPreference="Continue"
& $GodotPath @runArgs 2>&1 | Tee-Object -Variable runOutput
$engineExit=$LASTEXITCODE
$ErrorActionPreference="Stop"
if ($engineExit -ne 0 -or ($runOutput -match 'SCRIPT ERROR|ERROR:')) {throw "New project runtime failed."}
if ($Test -and -not ($runOutput -match '\[DNF_TEST\] COMPLETE checks=\d+ failures=0')) {throw "New project regression did not complete successfully."}
