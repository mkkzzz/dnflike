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
$assetLock=Join-Path $gamePath "asset_store.json"
$needsSync=-not (Test-Path -LiteralPath (Join-Path $gamePath "assets_local/manifest.json"))
if (Test-Path -LiteralPath $assetLock) {
    $sharedLock=Get-Content -LiteralPath $assetLock -Raw | ConvertFrom-Json
    $stampPath=Join-Path $gamePath "assets_local/.asset_store_install.json"
    if (Test-Path -LiteralPath $stampPath) {
        $installed=Get-Content -LiteralPath $stampPath -Raw | ConvertFrom-Json
        if ($installed.version -ne $sharedLock.version) {$needsSync=$true}
        foreach ($entry in @($sharedLock.packs | Where-Object {$_.kind -eq 'runtime'})) {
            if ($installed.runtime_packs.PSObject.Properties[$entry.name].Value -ne $entry.sha256) {$needsSync=$true}
        }
    } else {$needsSync=$true}
}
if ($needsSync) {
    if (Test-Path -LiteralPath $assetLock) {
        & python (Join-Path $PSScriptRoot "dnf_asset_store.py") sync
        if ($LASTEXITCODE -ne 0) {throw "Shared runtime asset sync failed. Check GitHub access and the network; see game_dnf/README.md."}
    } else {
        throw "Shared asset lock missing. Use -BuildAssets -LibraryPath <local extraction library>."
    }
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
# Compiled original content pack (doc 29 F2). Needs the full library; skipped when it is absent.
$contentPack=Join-Path $gamePath "assets_local/content/combat_content.json"
if (-not (Test-Path -LiteralPath $contentPack)) {
    & python (Join-Path $PSScriptRoot "compile_dnf_content.py") *> $null
    if ($LASTEXITCODE -ne 0) {Write-Output "Content pack not compiled (full library missing?); pack-dependent checks will be skipped."}
}
if ($Test) {
    & python (Join-Path $PSScriptRoot "check_dnf_deps.py")
    if ($LASTEXITCODE -ne 0) {throw "Module dependency check failed; see docs/design/29_新版工程框架.md."}
}
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
