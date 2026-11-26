[CmdletBinding()]
param(
    [string]$EngineDir = "C:\Program Files\Epic Games\UE_5.6",
    [switch]$SkipGeneratorBuild
)

$ErrorActionPreference = "Stop"

# All paths strictly anchored to $PSScriptRoot (runescape-dragonwilds-mods\scripts)
$RepoRoot          = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$GeneratorDir      = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\..\UE4GameProjectGenerator"))
$HeaderDumpDir     = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\UHTHeaderDump"))
$OutputStubDir     = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\RSDragonwilds"))

$GeneratorUProject = Join-Path $GeneratorDir "GameProjectGenerator.uproject"
$UECmd             = Join-Path $EngineDir "Engine\Binaries\Win64\UnrealEditor-Cmd.exe"
$BuildBat          = Join-Path $EngineDir "Engine\Build\BatchFiles\Build.bat"

# Optional extracted metadata files if placed in RepoRoot\extracted\
$ExtractedDir      = Join-Path $RepoRoot "extracted"
$ProjectFile       = Join-Path $ExtractedDir "RSDragonwilds.uproject"
$PluginManifest    = Join-Path $ExtractedDir "RSDragonwilds.upluginmanifest"

Write-Host "=== RSDragonwilds Stub Project Generator ===" -ForegroundColor Cyan
Write-Host "Script Dir     : $PSScriptRoot"
Write-Host "Repo Root      : $RepoRoot"
Write-Host "Generator Repo : $GeneratorDir"
Write-Host "Header Dump    : $HeaderDumpDir"
Write-Host "Output Project : $OutputStubDir`n"

# 1. Validate required paths
if (-not (Test-Path $UECmd)) {
    throw "UnrealEditor-Cmd.exe not found at: $UECmd"
}
if (-not (Test-Path $GeneratorUProject)) {
    throw "GameProjectGenerator.uproject not found at: $GeneratorUProject"
}
if (-not (Test-Path $HeaderDumpDir)) {
    throw "UHTHeaderDump folder not found at: $HeaderDumpDir"
}

# 2. Build UE4GameProjectGenerator
if (-not $SkipGeneratorBuild) {
    Write-Host "[1/2] Compiling GameProjectGenerator (Development Editor Win64)..." -ForegroundColor Yellow
    & $BuildBat ProjectGenerator Win64 Development "$GeneratorUProject" -WaitMutex -FromMsBuild
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to compile GameProjectGenerator (Exit Code: $LASTEXITCODE)."
    }
} else {
    Write-Host "[1/2] Skipping GameProjectGenerator compilation." -ForegroundColor DarkGray
}

# 3. Assemble Commandlet Arguments
if (-not (Test-Path $OutputStubDir)) {
    New-Item -ItemType Directory -Path $OutputStubDir | Out-Null
}

$CmdArgs = @(
    "`"$GeneratorUProject`"",
    "-run=ProjectGenerator",
    "-HeaderRoot=`"$HeaderDumpDir`"",
    "-OutputDir=`"$OutputStubDir`"",
    "-stdout",
    "-unattended",
    "-NoLogTimes"
)

if (Test-Path $ProjectFile) {
    Write-Host "Detected extracted .uproject: $ProjectFile" -ForegroundColor DarkCyan
    $CmdArgs += "-ProjectFile=`"$ProjectFile`""
}
if (Test-Path $PluginManifest) {
    Write-Host "Detected extracted .upluginmanifest: $PluginManifest" -ForegroundColor DarkCyan
    $CmdArgs += "-PluginManifest=`"$PluginManifest`""
}

# 4. Run the ProjectGenerator Commandlet
Write-Host "[2/2] Running ProjectGenerator commandlet..." -ForegroundColor Yellow
& $UECmd @CmdArgs
if ($LASTEXITCODE -ne 0) {
    throw "ProjectGenerator commandlet failed (Exit Code: $LASTEXITCODE)."
}

Write-Host "`nDone! Stub project generated at: $OutputStubDir" -ForegroundColor Green
