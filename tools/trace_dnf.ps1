param([Parameter(Mandatory)][string]$Label,[string]$Compare="")
# Headless presentation trace for the native battle (no window). Records per-frame view
# node state and every HUD draw call to temp/dnf_trace/<Label>.jsonl; with -Compare <label>
# reports the first differing frame. Used to prove refactors keep the picture unchanged.
$ErrorActionPreference="Stop"
$root=Split-Path $PSScriptRoot -Parent
$godot=Join-Path $PSScriptRoot "godot/Godot_v4.7.2-stable_win64_console.exe"
$game=Join-Path $root "game_dnf"
$dir=Join-Path $root "temp/dnf_trace"
New-Item -ItemType Directory -Force $dir | Out-Null
$file=Join-Path $dir "$Label.jsonl"
$ErrorActionPreference="Continue"
& $godot --headless --path $game --editor --import --quit 2>&1 | Out-Null
$out=& $godot --headless --path $game --fixed-fps 60 --quit-after 3500 -- --test "--trace=$file" 2>&1
$ErrorActionPreference="Stop"
$out | Select-String 'COMPLETE|FAIL|SCRIPT ERROR' | ForEach-Object { $_.Line }
$lines=@(Get-Content -LiteralPath $file -Encoding utf8)
"$Label frames=$($lines.Count) sha256=$((Get-FileHash -LiteralPath $file).Hash)"
if ($Compare) {
    $other=@(Get-Content -LiteralPath (Join-Path $dir "$Compare.jsonl") -Encoding utf8)
    $n=[Math]::Max($lines.Count,$other.Count)
    for ($i=0; $i -lt $n; $i++) {
        if ($lines[$i] -ne $other[$i]) {"FIRST_DIFF frame=$i"; "  $Compare : $($other[$i])"; "  $Label : $($lines[$i])"; exit 1}
    }
    "IDENTICAL to $Compare"
}
