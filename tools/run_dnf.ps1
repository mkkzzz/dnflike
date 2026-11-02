param([string]$GodotPath="",[switch]$Test,[switch]$Act8Test,[switch]$Capture,[switch]$Editor,[switch]$BuildAssets,[switch]$SyncAssets,[string]$LibraryPath="")
$ErrorActionPreference="Stop"
if ($Test -and $Act8Test) {throw "Use either -Test or -Act8Test, not both."}
& python (Join-Path $PSScriptRoot "check_dnf_numbers.py")
if ($LASTEXITCODE -ne 0) {throw "Numeric configuration invalid; check game_dnf/data/numbers.json."}
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
$assetLock=Join-Path $gamePath "asset_store.json"
# 2026-10-28 起运行时资源随仓库分发：清单在就直接用，不再比对安装标记。
# 需要按 Release 更新/重建时才加 -SyncAssets。
$needsSync=-not (Test-Path -LiteralPath (Join-Path $gamePath "assets_local/manifest.json"))
if ($SyncAssets) {$needsSync=$true}
if ($needsSync) {
    if (Test-Path -LiteralPath $assetLock) {
        & python (Join-Path $PSScriptRoot "dnf_asset_store.py") sync
        if ($LASTEXITCODE -ne 0) {throw "Shared runtime asset sync failed. Check GitHub access and the network; see game_dnf/README.md."}
    } else {
        throw "Shared asset lock missing. Use -BuildAssets -LibraryPath <local extraction library>."
    }
}
$ErrorActionPreference="Continue"
# The isolated act8 testbed ships its own deterministic generated inputs. Keep the shared
# production combat tree untouched while that tree may be under parallel development.
if (-not $Act8Test) {
    & (Join-Path $PSScriptRoot "ensure_dnf_combat.ps1")
}
$importOutput=& $GodotPath --headless --path $gamePath --editor --import --quit 2>&1
$importExit=$LASTEXITCODE
$ErrorActionPreference="Stop"
if ($importExit -ne 0 -or ($importOutput -match 'SCRIPT ERROR|ERROR:')) {
    $importOutput | Write-Output
    throw "New project import failed."
}
if ($Editor) {& $GodotPath --path $gamePath --editor; exit $LASTEXITCODE}
if ($Test -or $Act8Test) {
    & python (Join-Path $PSScriptRoot "check_dnf_deps.py")
    if ($LASTEXITCODE -ne 0) {throw "Module dependency check failed; see docs/design/29_新版工程框架.md."}
}
$runArgs=@("--path",$gamePath)
if ($Act8Test) {
    & python (Join-Path $PSScriptRoot "test_dnf_act8_testbed.py")
    if ($LASTEXITCODE -ne 0) {throw "Act8 testbed static checks failed."}
    $runArgs+="res://tests/act8/act8_test.tscn"
    $runArgs+=@("--fixed-fps","60","--quit-after","6000","--headless","--","--act8-test")
} elseif ($Test) {
	# Tests always target the combat scene, even when the user's editor main scene is the loop.
	$runArgs+="res://scenes/main.tscn"
    $runArgs+=@("--fixed-fps","60","--quit-after","3500")
    if ($Capture) {$runArgs+=@("--position","-32000,-32000")} else {$runArgs+="--headless"}
    $runArgs+=@("--","--test")
    if ($Capture) {$runArgs+="--capture"}
} elseif ($Capture) {$runArgs+=@("--","--capture")}
$ErrorActionPreference="Continue"
& $GodotPath @runArgs 2>&1 | Tee-Object -Variable runOutput
$engineExit=$LASTEXITCODE
$ErrorActionPreference="Stop"
$fatalOutput=@($runOutput | Where-Object { $_ -match 'SCRIPT ERROR|ERROR:' -and $_ -notmatch 'Unicode parsing error:' })
if ($engineExit -ne 0 -or $fatalOutput.Count -gt 0) {throw "New project runtime failed."}
if ($Act8Test -and -not ($runOutput -match '\[ACT8_TEST\] COMPLETE checks=\d+ failures=0')) {throw "Act8 testbed did not complete successfully."}
if ($Test -and -not ($runOutput -match '\[DNF_TEST\] COMPLETE checks=\d+ failures=0')) {throw "New project regression did not complete successfully."}
