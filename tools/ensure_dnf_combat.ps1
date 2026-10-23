# Ensures the original combat inputs exist before Godot imports game_dnf (doc 29 F2~F5):
#   assets_local/content/combat_content.json  (tools/compile_dnf_content.py)
#   assets_local/combat/manifest.json          (tools/build_dnf_combat_assets.py)
# Both need the full shared library (python tools/dnf_asset_store.py sync --full).
# Rebuilds when missing or when a generator script is newer than its output.
$ErrorActionPreference="Continue"
$repoRoot=Split-Path $PSScriptRoot -Parent
$local=Join-Path $repoRoot "game_dnf/assets_local"
$jobs=@(
    @{out=(Join-Path $local "content/combat_content.json"); tool="compile_dnf_content.py"; deps=@("compile_dnf_content.py","dnf_pvf.py")},
    @{out=(Join-Path $local "combat/manifest.json"); tool="build_dnf_combat_assets.py"; deps=@("build_dnf_combat_assets.py","dnf_locomotion.py","dnf_pvf.py")},
    # Original Lorien rooms used by the battle scene (also the T2 map preview's input).
    @{out=(Join-Path $local "native_maps/lorien/map_export.json"); tool="export_dnf_map.py"; deps=@("export_dnf_map.py")}
)
foreach ($job in $jobs) {
    $stale=-not (Test-Path -LiteralPath $job.out)
    if (-not $stale) {
        $built=(Get-Item -LiteralPath $job.out).LastWriteTimeUtc
        foreach ($dep in $job.deps) {
            if ((Get-Item -LiteralPath (Join-Path $PSScriptRoot $dep)).LastWriteTimeUtc -gt $built) {$stale=$true}
        }
    }
    if ($stale) {
        & python (Join-Path $PSScriptRoot $job.tool) *> $null
        if ($LASTEXITCODE -ne 0) {Write-Output "[DNF_COMBAT] $($job.tool) failed (full library missing? run python tools/dnf_asset_store.py sync --full)."}
    }
}
