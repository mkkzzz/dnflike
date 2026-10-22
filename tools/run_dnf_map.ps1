param([string]$GodotPath="",[switch]$Test,[switch]$Capture,[switch]$Export,[string]$Dungeon="dungeon/act1/lorien.dgn")
# T2 original-map verification scene; independent of the main game entry (run_dnf.ps1).
$ErrorActionPreference="Stop"
$repoRoot=Split-Path $PSScriptRoot -Parent
$gamePath=Join-Path $repoRoot "game_dnf"
if (-not $GodotPath) {$GodotPath=Join-Path $PSScriptRoot "godot/Godot_v4.7.2-stable_win64_console.exe"}
if (-not (Test-Path -LiteralPath $GodotPath)) {throw "Godot missing; run tools/setup_godot.ps1."}
$versionText="$(& $GodotPath --version 2>$null | Select-Object -First 1)".Trim()
if (-not $versionText.StartsWith("4.7.2.")) {throw "Godot 4.7.2 required; found $versionText"}
$exportJson=Join-Path $gamePath "assets_local/native_maps/lorien/map_export.json"
if ($Export -or -not (Test-Path -LiteralPath $exportJson)) {
    & python (Join-Path $PSScriptRoot "export_dnf_map.py") --dungeon $Dungeon
    if ($LASTEXITCODE -ne 0) {throw "Map export failed; run python tools/dnf_asset_store.py sync --full first."}
}
$ErrorActionPreference="Continue"
$importOutput=& $GodotPath --headless --path $gamePath --editor --import --quit 2>&1
$importExit=$LASTEXITCODE
$ErrorActionPreference="Stop"
if ($importExit -ne 0 -or ($importOutput -match 'SCRIPT ERROR|ERROR:')) {$importOutput | Write-Output; throw "Project import failed."}
$runArgs=@("--path",$gamePath,"--scene","res://scenes/map_preview.tscn")
if ($Test) {$runArgs+=@("--headless","--quit-after","3000","--","--test")}
elseif ($Capture) {$runArgs+=@("--position","-32000,-32000","--quit-after","6000","--","--capture")}
$ErrorActionPreference="Continue"
& $GodotPath @runArgs 2>&1 | Tee-Object -Variable runOutput
$engineExit=$LASTEXITCODE
$ErrorActionPreference="Stop"
if ($engineExit -ne 0 -or ($runOutput -match 'SCRIPT ERROR|ERROR:')) {throw "Map preview failed."}
if ($Test -and -not ($runOutput -match '\[MAP_TEST\] COMPLETE checks=\d+ failures=0')) {throw "Map preview checks did not pass."}
