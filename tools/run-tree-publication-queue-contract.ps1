param(
    [string]$ProjectPath = (Split-Path -Parent $PSScriptRoot),
    [string]$GodotExe = "C:\Users\arkam\Desktop\Godot_v4.6.1-stable_win64.exe\Godot_v4.6.1-stable_win64_console.exe"
)

& $GodotExe --headless --fixed-fps 60 --path $ProjectPath --script res://scripts/testing/TreePublicationQueueContractRunner.gd
exit $LASTEXITCODE
