param([string]$GodotPath="", [switch]$Test, [switch]$Capture, [switch]$BuildAssets, [string]$LibraryPath="")
$ErrorActionPreference="Stop"
$repoRoot=Split-Path $PSScriptRoot -Parent
$gamePath=Join-Path $repoRoot "game_dnf"
if (-not $GodotPath) {$GodotPath=Join-Path $PSScriptRoot "godot/Godot_v4.7.2-stable_win64_console.exe"}
if (-not (Test-Path -LiteralPath $GodotPath)) {throw "Run tools/setup_godot.ps1 first."}
$versionText="$(& $GodotPath --version 2>$null | Select-Object -First 1)".Trim()
if (-not $versionText.StartsWith("4.7.2.")) {throw "Godot 4.7.2 required; found $versionText"}
& python (Join-Path $PSScriptRoot "check_game_chinese.py")
if ($LASTEXITCODE -ne 0) {throw "Game text must use Chinese; Korean text is not permitted."}
if (-not (Test-Path -LiteralPath (Join-Path $gamePath "assets_local/manifest.json"))) {
    & python (Join-Path $PSScriptRoot "dnf_asset_store.py") sync
    if ($LASTEXITCODE -ne 0) {throw "Base runtime sync failed."}
}
if ($BuildAssets) {
    $buildArgs=@((Join-Path $PSScriptRoot "build_dnf_flow_assets.py"))
    if ($LibraryPath) {$buildArgs+=@("--library",$LibraryPath)}
    & python @buildArgs
    if ($LASTEXITCODE -ne 0) {throw "Native loop art build failed."}
} else {
    # Separate immutable pack needs no full library or original client installation.
    # Once installed, validate local version/hashes and play without network.
    & python (Join-Path $PSScriptRoot "sync_dnf_flow.py") --check-installed
    if ($LASTEXITCODE -ne 0) {
        & python (Join-Path $PSScriptRoot "sync_dnf_flow.py")
        if ($LASTEXITCODE -ne 0) {throw "Native loop art sync failed."}
    }
}
$ErrorActionPreference="Continue"
# Original combat inputs (ws1, doc 29 F2~F5): content pack + combat banks, built from the full library.
& (Join-Path $PSScriptRoot "ensure_dnf_combat.ps1")
$importOutput=& $GodotPath --headless --path $gamePath --editor --import --quit 2>&1
$importExit=$LASTEXITCODE
$ErrorActionPreference="Stop"
if ($importExit -ne 0 -or ($importOutput -match 'SCRIPT ERROR|ERROR:')) {
    $importOutput | Write-Output
    throw "Loop project import failed."
}
$runArgs=@("--path",$gamePath,"res://scenes/loop.tscn")
if ($Test) {
    $runArgs+=@("--fixed-fps","60","--quit-after","24000")
    if ($Capture) {$runArgs+=@("--position","-32000,-32000")} else {$runArgs+="--headless"}
    $runArgs+=@("--","--loop-test")
    if ($Capture) {$runArgs+="--capture"}
}
$ErrorActionPreference="Continue"
& $GodotPath @runArgs 2>&1 | Tee-Object -Variable runOutput
$engineExit=$LASTEXITCODE
$ErrorActionPreference="Stop"
if ($engineExit -ne 0 -or ($runOutput -match 'SCRIPT ERROR|ERROR:')) {throw "Native loop runtime failed."}
if ($Test -and -not ($runOutput -match '\[LOOP_TEST\] COMPLETE checks=\d+ failures=0')) {throw "Native loop checks did not complete."}
