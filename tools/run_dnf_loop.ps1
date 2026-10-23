param([string]$GodotPath="", [switch]$Test, [switch]$Capture, [switch]$BuildAssets, [string]$LibraryPath="", [switch]$NumbersOnly, [switch]$QuestsOnly, [switch]$ItemsOnly)
$ErrorActionPreference="Stop"
& python (Join-Path $PSScriptRoot "check_dnf_numbers.py")
if ($LASTEXITCODE -ne 0) {throw "Numeric configuration invalid; check game_dnf/data/numbers.json."}
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
    $questBuildArgs=@((Join-Path $PSScriptRoot "build_dnf_quest_assets.py"))
    if ($LibraryPath) {$questBuildArgs+=@("--library",$LibraryPath)}
    & python @questBuildArgs
    if ($LASTEXITCODE -ne 0) {throw "Original quest art build failed."}
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
# Item icons have an independent lock so town art releases remain independent.
& python (Join-Path $PSScriptRoot "dnf_items_assets.py") sync --check-installed
if ($LASTEXITCODE -ne 0) {
    & python (Join-Path $PSScriptRoot "dnf_items_assets.py") sync
    if ($LASTEXITCODE -ne 0) {throw "Original item icon sync failed."}
}
# Original combat inputs (ws1, doc 29 F2~F5): content pack + combat banks, built from the full library.
& (Join-Path $PSScriptRoot "ensure_dnf_combat.ps1")
$importOutput=& $GodotPath --headless --path $gamePath --editor --import --quit 2>&1
$importExit=$LASTEXITCODE
$ErrorActionPreference="Stop"
if ($importExit -ne 0 -or ($importOutput -match 'SCRIPT ERROR|ERROR:')) {
    $importOutput | Write-Output
    throw "Loop project import failed."
}
if ($Test) {
    $itemOutput=& $GodotPath --headless --path $gamePath --script res://tests/items/test_inventory.gd 2>&1
    $itemOutput | Write-Output
    if ($LASTEXITCODE -ne 0 -or ($itemOutput -match 'SCRIPT ERROR|ERROR:') -or -not ($itemOutput -match '\[ITEM_TEST\] COMPLETE checks=\d+ failures=0')) {throw "Item regression failed."}
    $numericOutput=& $GodotPath --headless --path $gamePath --script res://tests/stats/test_numbers.gd 2>&1
    $numericOutput | Write-Output
    if ($LASTEXITCODE -ne 0 -or ($numericOutput -match 'SCRIPT ERROR|ERROR:') -or -not ($numericOutput -match '\[NUMBERS_TEST\] COMPLETE checks=\d+ failures=0')) {throw "Numeric regression failed."}
    $questOutput=& $GodotPath --headless --path $gamePath --quit-after 1000 --script res://tests/quests/run_quests.gd 2>&1
    $questOutput | Write-Output
    if ($LASTEXITCODE -ne 0 -or ($questOutput -match 'SCRIPT ERROR|ERROR:') -or -not ($questOutput -match '\[QUEST_TEST\] COMPLETE checks=\d+ failures=0')) {throw "Quest unit regression failed."}
}
$runArgs=@("--path",$gamePath,"res://scenes/loop.tscn")
if ($Test) {
    $runArgs+=@("--fixed-fps","60","--quit-after","24000")
    if ($Capture) {$runArgs+=@("--position","-32000,-32000")} else {$runArgs+="--headless"}
    $runArgs+=@("--","--loop-test")
    if ($NumbersOnly) {$runArgs+="--numbers-only"}
    if ($QuestsOnly) {$runArgs+="--quests-only"}
    if ($ItemsOnly) {$runArgs+="--items-only"}
    if ($Capture) {$runArgs+="--capture"}
}
$ErrorActionPreference="Continue"
& $GodotPath @runArgs 2>&1 | Tee-Object -Variable runOutput
$engineExit=$LASTEXITCODE
$ErrorActionPreference="Stop"
if ($engineExit -ne 0 -or ($runOutput -match 'SCRIPT ERROR|ERROR:')) {throw "Native loop runtime failed."}
if ($Test -and -not ($runOutput -match $(if ($QuestsOnly) {'\[QUEST_CHAPTER\] COMPLETE checks=\d+ failures=0'} else {'\[LOOP_TEST\] COMPLETE checks=\d+ failures=0'}))) {throw "Native loop checks did not complete."}
