# 一键安装 Godot 免安装版到 tools/godot（新机器首次拉取后运行一次）
$ErrorActionPreference = "Stop"
$ver = "4.7.2-stable"
$dir = Join-Path $PSScriptRoot "godot"
if (Test-Path (Join-Path $dir "Godot_v$ver`_win64.exe")) {
    Write-Host "Godot $ver 已存在：$dir" -ForegroundColor Green
    exit 0
}
$url = "https://github.com/godotengine/godot/releases/download/$ver/Godot_v$ver`_win64.exe.zip"
$zip = "$env:TEMP\godot.zip"
Write-Host "下载 $url"
Invoke-WebRequest -Uri $url -OutFile $zip
New-Item -ItemType Directory -Force -Path $dir | Out-Null
Expand-Archive -Path $zip -DestinationPath $dir -Force
Remove-Item $zip
Write-Host "完成。运行方式：$dir\Godot_v$ver`_win64.exe --path ..\..\game" -ForegroundColor Green
