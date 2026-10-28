param([string]$GodotPath="", [switch]$Test, [switch]$Capture, [switch]$BuildAssets, [switch]$SyncAssets, [string]$LibraryPath="", [switch]$NumbersOnly, [switch]$QuestsOnly, [switch]$ItemsOnly, [switch]$TownsOnly, [switch]$ServicesOnly, [switch]$GranOnly, [switch]$UpgradesOnly, [switch]$RecoveryOnly)
$ErrorActionPreference="Stop"
& python (Join-Path $PSScriptRoot "check_dnf_numbers.py")
if ($LASTEXITCODE -ne 0) {throw "Numeric configuration invalid; check game_dnf/data/numbers.json."}
& python (Join-Path $PSScriptRoot "check_dnf_services.py")
if ($LASTEXITCODE -ne 0) {throw "Town service configuration invalid."}
& python (Join-Path $PSScriptRoot "check_dnf_upgrades.py")
if ($LASTEXITCODE -ne 0) {throw "Equipment upgrade configuration invalid."}
& python (Join-Path $PSScriptRoot "check_dnf_recovery.py")
if ($LASTEXITCODE -ne 0) {throw "Recovery configuration invalid."}
$repoRoot=Split-Path $PSScriptRoot -Parent
$gamePath=Join-Path $repoRoot "game_dnf"
# 2026-10-28 起运行时资源随仓库分发：清单在就直接用，各 sync/烘焙步骤默认跳过。
# 需要按 Release 更新或从原版库重建时才加 -SyncAssets（或 -BuildAssets）。
$assetsBundled=(Test-Path -LiteralPath (Join-Path $gamePath "assets_local/manifest.json")) -and -not $SyncAssets
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
    $townBuildArgs=@((Join-Path $PSScriptRoot "build_dnf_hendon_assets.py"))
    if ($LibraryPath) {$townBuildArgs+=@("--library",$LibraryPath)}
    & python @townBuildArgs
    if ($LASTEXITCODE -ne 0) {throw "Original Hendon art build failed."}
    $granBuildArgs=@((Join-Path $PSScriptRoot "build_dnf_gran_assets.py"))
    if ($LibraryPath) {$granBuildArgs+=@("--library",$LibraryPath)}
    & python @granBuildArgs
    if ($LASTEXITCODE -ne 0) {throw "Original Granfloris art build failed."}
} elseif (-not $assetsBundled) {
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
if (-not $assetsBundled) {
    & python (Join-Path $PSScriptRoot "dnf_items_assets.py") sync --check-installed
    if ($LASTEXITCODE -ne 0) {
        & python (Join-Path $PSScriptRoot "dnf_items_assets.py") sync
        if ($LASTEXITCODE -ne 0) {throw "Original item icon sync failed."}
    }
}
# Original combat inputs (ws1, doc 29 F2~F5): content pack + combat banks, built from the full library.
if (-not $assetsBundled) {& (Join-Path $PSScriptRoot "ensure_dnf_combat.ps1")}
# Town portal gate light (ws4): original gateup/gatedown frames, also built from the full library.
$gateOut=Join-Path $gamePath "assets_local/town_gate/manifest.json"
$gateTool=Join-Path $PSScriptRoot "bake_town_gate_light.py"
$gateStale=(-not $assetsBundled) -and (-not (Test-Path -LiteralPath $gateOut))
if (-not $gateStale -and -not $assetsBundled) {$gateStale=(Get-Item -LiteralPath $gateTool).LastWriteTimeUtc -gt (Get-Item -LiteralPath $gateOut).LastWriteTimeUtc}
if ($gateStale) {
    & python $gateTool *> $null
    if ($LASTEXITCODE -ne 0) {Write-Output "[DNF_GATE] bake_town_gate_light.py failed (full library missing? run python tools/dnf_asset_store.py sync --full)"}
}
$importOutput=& $GodotPath --headless --path $gamePath --editor --import --quit 2>&1
$importExit=$LASTEXITCODE
$ErrorActionPreference="Stop"
if ($importExit -ne 0 -or ($importOutput -match 'SCRIPT ERROR|ERROR:')) {
    $importOutput | Write-Output
    throw "Loop project import failed."
}
if ($Test) {
    $recoveryOutput=& $GodotPath --headless --path $gamePath --script res://tests/items/test_recovery.gd 2>&1
    $recoveryOutput | Write-Output
    if ($LASTEXITCODE -ne 0 -or ($recoveryOutput -match 'SCRIPT ERROR|ERROR:') -or -not ($recoveryOutput -match '\[RECOVERY_TEST\] COMPLETE checks=\d+ failures=0')) {throw "Recovery regression failed."}
    $upgradeOutput=& $GodotPath --headless --path $gamePath --script res://tests/items/test_upgrades.gd 2>&1
    $upgradeOutput | Write-Output
    if ($LASTEXITCODE -ne 0 -or ($upgradeOutput -match 'SCRIPT ERROR|ERROR:') -or -not ($upgradeOutput -match '\[UPGRADE_TEST\] COMPLETE checks=\d+ failures=0')) {throw "Upgrade regression failed."}
    $serviceOutput=& $GodotPath --headless --path $gamePath --script res://tests/items/test_services.gd 2>&1
    $serviceOutput | Write-Output
    if ($LASTEXITCODE -ne 0 -or ($serviceOutput -match 'SCRIPT ERROR|ERROR:') -or -not ($serviceOutput -match '\[SERVICE_TEST\] COMPLETE checks=\d+ failures=0')) {throw "Service regression failed."}
    $itemOutput=& $GodotPath --headless --path $gamePath --script res://tests/items/test_inventory.gd 2>&1
    $itemOutput | Write-Output
    if ($LASTEXITCODE -ne 0 -or ($itemOutput -match 'SCRIPT ERROR|ERROR:') -or -not ($itemOutput -match '\[ITEM_TEST\] COMPLETE checks=\d+ failures=0')) {throw "Item regression failed."}
    $numericOutput=& $GodotPath --headless --path $gamePath --script res://tests/stats/test_numbers.gd 2>&1
    $numericOutput | Write-Output
    if ($LASTEXITCODE -ne 0 -or ($numericOutput -match 'SCRIPT ERROR|ERROR:') -or -not ($numericOutput -match '\[NUMBERS_TEST\] COMPLETE checks=\d+ failures=0')) {throw "Numeric regression failed."}
    $questOutput=& $GodotPath --headless --path $gamePath --quit-after 1000 --script res://tests/quests/run_quests.gd 2>&1
    $questOutput | Write-Output
    if ($LASTEXITCODE -ne 0 -or ($questOutput -match 'SCRIPT ERROR|ERROR:') -or -not ($questOutput -match '\[QUEST_TEST\] COMPLETE checks=\d+ failures=0')) {throw "Quest unit regression failed."}
    $worldOutput=& $GodotPath --headless --path $gamePath --quit-after 1000 --script res://tests/town/run_world.gd 2>&1
    $worldOutput | Write-Output
    if ($LASTEXITCODE -ne 0 -or ($worldOutput -match 'SCRIPT ERROR|ERROR:') -or -not ($worldOutput -match '\[TOWN_UNIT\] COMPLETE checks=\d+ failures=0')) {throw "Town topology regression failed."}
    $granOutput=& $GodotPath --headless --path $gamePath --quit-after 1000 --script res://tests/quests/run_gran_rules.gd 2>&1
    $granOutput | Write-Output
    if ($LASTEXITCODE -ne 0 -or ($granOutput -match 'SCRIPT ERROR|ERROR:') -or -not ($granOutput -match '\[GRAN_UNIT\] COMPLETE checks=\d+ failures=0')) {throw "Granfloris source task regression failed."}
}
$runArgs=@("--path",$gamePath,"res://scenes/loop.tscn")
if ($Test) {
    $runArgs+=@("--fixed-fps","60","--quit-after",$(if ($GranOnly) {"80000"} else {"24000"}))
    if ($Capture) {$runArgs+=@("--position","-32000,-32000")} else {$runArgs+="--headless"}
    $runArgs+=@("--","--loop-test")
    if ($NumbersOnly) {$runArgs+="--numbers-only"}
    if ($QuestsOnly) {$runArgs+="--quests-only"}
    if ($ItemsOnly) {$runArgs+="--items-only"}
    if ($ServicesOnly) {$runArgs+="--services-only"}
    if ($UpgradesOnly) {$runArgs+="--upgrades-only"}
    if ($RecoveryOnly) {$runArgs+="--recovery-only"}
    if ($TownsOnly) {$runArgs+="--towns-only"}
    if ($GranOnly) {$runArgs+="--gran-only"}
    if ($Capture) {$runArgs+="--capture"}
}
$ErrorActionPreference="Continue"
& $GodotPath @runArgs 2>&1 | Tee-Object -Variable runOutput
$engineExit=$LASTEXITCODE
$ErrorActionPreference="Stop"
if ($engineExit -ne 0 -or ($runOutput -match 'SCRIPT ERROR|ERROR:')) {throw "Native loop runtime failed."}
if ($Test -and -not ($runOutput -match $(if ($GranOnly) {'\[GRAN_CHAPTER\] COMPLETE checks=\d+ failures=0'} elseif ($TownsOnly) {'\[HENDON_TEST\] COMPLETE checks=\d+ failures=0'} elseif ($QuestsOnly) {'\[QUEST_CHAPTER\] COMPLETE checks=\d+ failures=0'} else {'\[LOOP_TEST\] COMPLETE checks=\d+ failures=0'}))) {throw "Native loop checks did not complete."}
