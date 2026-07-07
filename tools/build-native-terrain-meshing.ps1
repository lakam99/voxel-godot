param(
    [switch]$FetchGodotCpp,
    [string]$GodotCppBranch = "master",
    [string]$Target = "template_debug",
    [string]$Platform = "windows",
    [string]$Architecture = "x86_64",
    [string]$ApiVersion = "4.6"
)

$ErrorActionPreference = "Stop"

$projectPath = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$nativePath = Join-Path $projectPath "native\terrain_meshing"
$godotCppPath = Join-Path $nativePath "godot-cpp"
$customSConsToolsPath = Join-Path $nativePath "scons_tools"
$addonsPath = Join-Path $projectPath "addons\terrain_meshing_backend"
$addonsBinPath = Join-Path $addonsPath "bin"

function Resolve-SConsInvocation {
    $scons = Get-Command scons -ErrorAction SilentlyContinue
    if ($scons -ne $null) {
        return @{
            Executable = $scons.Source
            Arguments = @()
            Label = $scons.Source
        }
    }
    $pythonScriptsSCons = Join-Path $env:APPDATA "Python\Python314\Scripts\scons.exe"
    if (Test-Path -LiteralPath $pythonScriptsSCons) {
        return @{
            Executable = $pythonScriptsSCons
            Arguments = @()
            Label = $pythonScriptsSCons
        }
    }
    $python = Get-Command python -ErrorAction SilentlyContinue
    if ($python -ne $null) {
        & $python.Source -m SCons --version *> $null
        if ($LASTEXITCODE -eq 0) {
            return @{
                Executable = $python.Source
                Arguments = @("-m", "SCons")
                Label = "$($python.Source) -m SCons"
            }
        }
    }
    throw "Missing scons on PATH and no Python SCons module was found. Install SCons before building the terrain meshing GDExtension."
}

function Import-VisualStudioBuildEnvironment {
    if ($env:VCINSTALLDIR -and $env:INCLUDE -and $env:LIB) {
        return
    }
    $candidateBatches = @(
        "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat",
        "C:\Program Files\Microsoft Visual Studio\2022\Community\Common7\Tools\VsDevCmd.bat",
        "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\Common7\Tools\VsDevCmd.bat"
    )
    $batchPath = ""
    foreach ($candidate in $candidateBatches) {
        if (Test-Path -LiteralPath $candidate) {
            $batchPath = $candidate
            break
        }
    }
    if ($batchPath -eq "") {
        return
    }
    $arguments = ">nul && set"
    if ([System.IO.Path]::GetFileName($batchPath).ToLowerInvariant() -eq "vsdevcmd.bat") {
        $arguments = "-arch=x64 -host_arch=x64 >nul && set"
    }
    $environmentLines = & cmd.exe /s /c "`"$batchPath`" $arguments"
    foreach ($line in $environmentLines) {
        $index = $line.IndexOf("=")
        if ($index -le 0) {
            continue
        }
        $name = $line.Substring(0, $index)
        $value = $line.Substring($index + 1)
        [System.Environment]::SetEnvironmentVariable($name, $value, "Process")
    }
}

if (-not (Test-Path -LiteralPath $nativePath)) {
    throw "Missing native terrain meshing source directory: $nativePath"
}

if ($FetchGodotCpp -and -not (Test-Path -LiteralPath $godotCppPath)) {
    git clone --depth 1 --branch $GodotCppBranch https://github.com/godotengine/godot-cpp.git $godotCppPath
}

$godotCppSConstruct = Join-Path $godotCppPath "SConstruct"
if (-not (Test-Path -LiteralPath $godotCppSConstruct)) {
    throw "Missing godot-cpp bindings at $godotCppPath. Re-run with -FetchGodotCpp or set up the dependency manually."
}

$sconsInvocation = Resolve-SConsInvocation
Import-VisualStudioBuildEnvironment

$compilerAvailable = $false
foreach ($candidate in @("cl", "clang", "clang++", "gcc", "g++")) {
    if (Get-Command $candidate -ErrorAction SilentlyContinue) {
        $compilerAvailable = $true
        break
    }
}
if (-not $compilerAvailable) {
    Write-Warning "No C++ compiler found on PATH. Continuing so SCons can attempt platform toolchain discovery; install MSVC Build Tools, clang, or gcc if the build fails."
}

Push-Location $nativePath
try {
    & $sconsInvocation.Executable @($sconsInvocation.Arguments + @("platform=$Platform", "target=$Target", "arch=$Architecture", "api_version=$ApiVersion", "custom_tools=$customSConsToolsPath"))
    if ($LASTEXITCODE -ne 0) {
        throw "SCons failed with exit code $LASTEXITCODE"
    }
}
finally {
    Pop-Location
}

New-Item -ItemType Directory -Force -Path $addonsBinPath | Out-Null
$builtLibraries = Get-ChildItem -Path (Join-Path $nativePath "bin") -File -Recurse | Where-Object {
    $_.Name -like "*terrain_meshing_backend*"
}
if ($builtLibraries.Count -le 0) {
    throw "Build finished but no terrain_meshing_backend library was produced."
}
foreach ($library in $builtLibraries) {
    Copy-Item -LiteralPath $library.FullName -Destination (Join-Path $addonsBinPath $library.Name) -Force
}

Copy-Item -LiteralPath (Join-Path $nativePath "terrain_meshing_backend.gdextension.in") -Destination (Join-Path $addonsPath "terrain_meshing_backend.gdextension") -Force

[pscustomobject]@{
    status = "installed"
    nativePath = $nativePath
    addonPath = $addonsPath
    libraries = @($builtLibraries | ForEach-Object { $_.Name })
} | ConvertTo-Json -Depth 8
