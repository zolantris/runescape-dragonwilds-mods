[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$ModFolder,
    [string]$GameDir = $(if ($env:RSDW_GAME_DIR) { $env:RSDW_GAME_DIR } else { "C:\steam\steamapps\common\RSDragonwilds" })
)

$ErrorActionPreference = "Stop"
$deployScript = Join-Path $PSScriptRoot "deploy-mod.ps1"
if (-not (Test-Path -LiteralPath $deployScript -PathType Leaf)) {
    throw "Missing deploy script at '$deployScript'."
}

& $deployScript -ModFolder $ModFolder -GameDir $GameDir -Wipe -WhatIf:$WhatIfPreference
