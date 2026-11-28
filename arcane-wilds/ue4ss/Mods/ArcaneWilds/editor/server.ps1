param(
    [string]$ModDir = "",
    [string]$UserDir = "",
    [int]$Port = 47821,
    [switch]$NoBrowser
)

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if ([string]::IsNullOrWhiteSpace($ModDir)) {
    $ModDir = Split-Path -Parent $scriptDir
}
$ModDir = (Resolve-Path -LiteralPath $ModDir).Path

if ([string]::IsNullOrWhiteSpace($UserDir)) {
    if ($env:ARCANE_WILDS_USER_DIR) {
        $UserDir = $env:ARCANE_WILDS_USER_DIR
    } elseif ($env:LOCALAPPDATA) {
        $UserDir = Join-Path $env:LOCALAPPDATA "ArcaneWilds"
    } else {
        $UserDir = Join-Path $ModDir "user"
    }
}
if (-not (Test-Path -LiteralPath $UserDir -PathType Container)) {
    New-Item -ItemType Directory -Force -Path $UserDir | Out-Null
}
$UserDir = (Resolve-Path -LiteralPath $UserDir).Path
$editorDir = $scriptDir

$mimeTypes = @{
    ".html" = "text/html; charset=utf-8"
    ".css"  = "text/css; charset=utf-8"
    ".js"   = "application/javascript; charset=utf-8"
    ".json" = "application/json; charset=utf-8"
    ".svg"  = "image/svg+xml"
    ".png"  = "image/png"
    ".ico"  = "image/x-icon"
}

function Get-FileMtimeIso {
    param([string]$Path)
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        return (Get-Item -LiteralPath $Path).LastWriteTimeUtc.ToString("o")
    }
    return $null
}

function Write-JsonResponse {
    param(
        [System.Net.HttpListenerResponse]$Response,
        [int]$StatusCode,
        [string]$JsonText
    )
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($JsonText)
    $Response.StatusCode = $StatusCode
    $Response.ContentType = "application/json; charset=utf-8"
    $Response.Headers["Cache-Control"] = "no-store"
    $Response.ContentLength64 = $bytes.Length
    $Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $Response.OutputStream.Close()
}

function Read-RequestBody {
    param([System.Net.HttpListenerRequest]$Request)
    $reader = New-Object System.IO.StreamReader($Request.InputStream, [System.Text.Encoding]::UTF8)
    try {
        return $reader.ReadToEnd()
    } finally {
        $reader.Dispose()
    }
}

function Save-JsonAtomically {
    param(
        [string]$TargetPath,
        [string]$JsonText
    )
    # Validate JSON parses cleanly before touching disk
    $null = $JsonText | ConvertFrom-Json

    if (Test-Path -LiteralPath $TargetPath -PathType Leaf) {
        $bakPath = "$TargetPath.bak"
        Copy-Item -LiteralPath $TargetPath -Destination $bakPath -Force
    }
    $tmpPath = "$TargetPath.tmp"
    [System.IO.File]::WriteAllText($tmpPath, $JsonText.TrimEnd() + "`n", (New-Object System.Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $tmpPath -Destination $TargetPath -Force
}

function Build-FallbackCatalog {
    param([string]$BaseDir)

    $categoriesSet = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)
    $spellsMap = @{}
    $vfxMap = @{}
    $sfxMap = @{}
    $montagesMap = @{}

    # 1. Parse spell_names.txt for baseline categories, spells & friendly aliases
    $spellNamesPath = Join-Path $BaseDir "spell_names.txt"
    if (Test-Path -LiteralPath $spellNamesPath -PathType Leaf) {
        foreach ($line in (Get-Content -LiteralPath $spellNamesPath)) {
            $clean = $line.Trim()
            if ($clean -eq "" -or $clean.StartsWith("#") -or $clean.StartsWith(";")) { continue }
            $hashIdx = $clean.IndexOf("#")
            if ($hashIdx -ge 0) { $clean = $clean.Substring(0, $hashIdx).Trim() }
            $eqIdx = $clean.IndexOf("=")
            if ($eqIdx -le 0) { continue }
            $lhs = $clean.Substring(0, $eqIdx).Trim()
            $rhs = $clean.Substring($eqIdx + 1).Trim()
            if ($lhs -eq "" -or $rhs -eq "") { continue }

            $cat = ""
            $alias = $lhs
            $dotIdx = $lhs.IndexOf(".")
            if ($dotIdx -gt 0) {
                $cat = $lhs.Substring(0, $dotIdx).Trim()
                $alias = $lhs.Substring($dotIdx + 1).Trim()
            }
            if ($cat -ne "" -and $cat -ne "*") { [void]$categoriesSet.Add($cat) }

            $key = $rhs.ToLowerInvariant()
            if (-not $spellsMap.ContainsKey($key)) {
                $spellsMap[$key] = [ordered]@{
                    shortName = $rhs
                    fullName  = ""
                    category  = if ($cat -eq "*") { "" } else { $cat }
                    stepIndex = 0
                    montage   = $null
                    aliases   = New-Object System.Collections.ArrayList
                    isModded  = $false
                    isSpecial = $false
                }
            }
            if ($alias -ne "" -and -not $spellsMap[$key].aliases.Contains($alias)) {
                [void]$spellsMap[$key].aliases.Add($alias)
            }
        }
    }

    # 2. Parse detected_spells.txt if present
    $detectedSpellsPath = Join-Path $BaseDir "detected_spells.txt"
    if (Test-Path -LiteralPath $detectedSpellsPath -PathType Leaf) {
        $currentCat = ""
        foreach ($line in (Get-Content -LiteralPath $detectedSpellsPath)) {
            if ($line -match '^\[([^\]]+)\]') {
                $currentCat = $Matches[1].Trim()
                if ($currentCat -ne "") { [void]$categoriesSet.Add($currentCat) }
                continue
            }
            if ($line -match '^\s+([A-Za-z0-9_]+)') {
                $sName = $Matches[1].Trim()
                $montage = $null
                if ($line -match '\(Montage:\s*([^)]+)\)') {
                    $montage = $Matches[1].Trim()
                    $mKey = $montage.ToLowerInvariant()
                    if (-not $montagesMap.ContainsKey($mKey)) {
                        $montagesMap[$mKey] = [ordered]@{ shortName = $montage; path = $montage }
                    }
                }
                $key = $sName.ToLowerInvariant()
                if (-not $spellsMap.ContainsKey($key)) {
                    $spellsMap[$key] = [ordered]@{
                        shortName = $sName
                        fullName  = ""
                        category  = $currentCat
                        stepIndex = 0
                        montage   = $montage
                        aliases   = New-Object System.Collections.ArrayList
                        isModded  = $false
                        isSpecial = $false
                    }
                } else {
                    if ($currentCat -ne "" -and [string]::IsNullOrEmpty($spellsMap[$key].category)) {
                        $spellsMap[$key].category = $currentCat
                    }
                    if ($montage -and -not $spellsMap[$key].montage) {
                        $spellsMap[$key].montage = $montage
                    }
                }
            }
        }
    }

    # 3. Parse detected_vfx.txt & vfx_names.txt
    foreach ($vfName in @("detected_vfx.txt", "vfx_names.txt")) {
        $vfPath = Join-Path $BaseDir $vfName
        if (-not (Test-Path -LiteralPath $vfPath -PathType Leaf)) { continue }
        foreach ($line in (Get-Content -LiteralPath $vfPath)) {
            $clean = $line.Trim()
            if ($clean -eq "" -or $clean.StartsWith("#") -or $clean.StartsWith(";")) { continue }
            $eqIdx = $clean.IndexOf("=")
            if ($eqIdx -le 0) { continue }
            $lhs = $clean.Substring(0, $eqIdx).Trim()
            $rhs = $clean.Substring($eqIdx + 1).Trim()
            if ($rhs -eq "") { continue }
            $pKey = $rhs.ToLowerInvariant()
            $short = ($rhs -split '[./:]')[-1]
            if (-not $vfxMap.ContainsKey($pKey)) {
                $vfxMap[$pKey] = [ordered]@{
                    shortName = if ($short) { $short } else { $lhs }
                    path      = $rhs
                    kind      = "niagara"
                    aliases   = New-Object System.Collections.ArrayList
                }
            }
            if ($lhs -ne "" -and $lhs -ine $vfxMap[$pKey].shortName -and -not $vfxMap[$pKey].aliases.Contains($lhs)) {
                [void]$vfxMap[$pKey].aliases.Add($lhs)
            }
        }
    }

    # 4. Parse sfx_names.txt if present
    $sfxNamesPath = Join-Path $BaseDir "sfx_names.txt"
    if (Test-Path -LiteralPath $sfxNamesPath -PathType Leaf) {
        foreach ($line in (Get-Content -LiteralPath $sfxNamesPath)) {
            $clean = $line.Trim()
            if ($clean -eq "" -or $clean.StartsWith("#") -or $clean.StartsWith(";")) { continue }
            $eqIdx = $clean.IndexOf("=")
            if ($eqIdx -le 0) { continue }
            $lhs = $clean.Substring(0, $eqIdx).Trim()
            $rhs = $clean.Substring($eqIdx + 1).Trim()
            if ($rhs -eq "") { continue }
            $pKey = $rhs.ToLowerInvariant()
            $short = ($rhs -split '[./:]')[-1]
            if (-not $sfxMap.ContainsKey($pKey)) {
                $sfxMap[$pKey] = [ordered]@{
                    shortName = if ($short) { $short } else { $lhs }
                    path      = $rhs
                    kind      = "sound"
                    aliases   = New-Object System.Collections.ArrayList
                }
            }
            if ($lhs -ne "" -and $lhs -ine $sfxMap[$pKey].shortName -and -not $sfxMap[$pKey].aliases.Contains($lhs)) {
                [void]$sfxMap[$pKey].aliases.Add($lhs)
            }
        }
    }

    # Also seed common VFX/SFX/Montage references found in custom_spells.json so offline editing works immediately
    $customSpellsPath = Join-Path $BaseDir "custom_spells.json"
    if (Test-Path -LiteralPath $customSpellsPath -PathType Leaf) {
        try {
            $csObj = Get-Content -LiteralPath $customSpellsPath -Raw | ConvertFrom-Json
            if ($csObj.spells) {
                foreach ($prop in $csObj.spells.PSObject.Properties) {
                    $sp = $prop.Value
                    if ($sp.category) { [void]$categoriesSet.Add([string]$sp.category) }
                    if ($sp.montage) {
                        $mk = ([string]$sp.montage).ToLowerInvariant()
                        if (-not $montagesMap.ContainsKey($mk)) {
                            $montagesMap[$mk] = [ordered]@{ shortName = [string]$sp.montage; path = [string]$sp.montage }
                        }
                    }
                    if ($sp.cues) {
                        foreach ($cue in $sp.cues) {
                            $ct = [string]$cue.type
                            $asset = [string]$cue.asset
                            if ($ct -eq "vfx" -and $asset -ne "") {
                                $pk = $asset.ToLowerInvariant()
                                $sh = ($asset -split '[./:]')[-1]
                                if (-not $vfxMap.ContainsKey($pk)) {
                                    $vfxMap[$pk] = [ordered]@{ shortName = $sh; path = $asset; kind = "niagara"; aliases = @() }
                                }
                            } elseif ($ct -eq "sfx" -and $asset -ne "") {
                                $pk = $asset.ToLowerInvariant()
                                $sh = ($asset -split '[./:]')[-1]
                                if (-not $sfxMap.ContainsKey($pk)) {
                                    $sfxMap[$pk] = [ordered]@{ shortName = $sh; path = $asset; kind = "sound"; aliases = @() }
                                }
                            } elseif (($ct -eq "anim" -or $ct -eq "weaponAnim" -or $ct -eq "targetAnim") -and $asset -ne "") {
                                $mk = $asset.ToLowerInvariant()
                                $sh = ($asset -split '[./:]')[-1]
                                if (-not $montagesMap.ContainsKey($mk)) {
                                    $montagesMap[$mk] = [ordered]@{ shortName = $sh; path = $asset }
                                }
                            }
                            if ($cue.sfx) {
                                $sa = [string]$cue.sfx
                                $pk = $sa.ToLowerInvariant()
                                if (-not $sfxMap.ContainsKey($pk)) {
                                    $sfxMap[$pk] = [ordered]@{ shortName = $sa; path = $sa; kind = "keyword"; aliases = @() }
                                }
                            }
                            if ($cue.vfx) {
                                $va = [string]$cue.vfx
                                $pk = $va.ToLowerInvariant()
                                if (-not $vfxMap.ContainsKey($pk)) {
                                    $vfxMap[$pk] = [ordered]@{ shortName = $va; path = $va; kind = "keyword"; aliases = @() }
                                }
                            }
                        }
                    }
                }
            }
        } catch {
            # Ignore parse issues in fallback seeding
        }
    }

    $sortedCats = @($categoriesSet | Sort-Object)
    $sortedSpells = @($spellsMap.Values | ForEach-Object {
        [ordered]@{
            shortName = $_.shortName
            fullName  = $_.fullName
            category  = $_.category
            stepIndex = $_.stepIndex
            montage   = $_.montage
            aliases   = @($_.aliases | Sort-Object)
            isModded  = $_.isModded
            isSpecial = $_.isSpecial
        }
    } | Sort-Object category, shortName)
    $sortedVfx = @($vfxMap.Values | ForEach-Object {
        [ordered]@{
            shortName = $_.shortName
            path      = $_.path
            kind      = $_.kind
            aliases   = @($_.aliases | Sort-Object)
        }
    } | Sort-Object shortName)
    $sortedSfx = @($sfxMap.Values | ForEach-Object {
        [ordered]@{
            shortName = $_.shortName
            path      = $_.path
            kind      = $_.kind
            aliases   = @($_.aliases | Sort-Object)
        }
    } | Sort-Object shortName)
    $sortedMontages = @($montagesMap.Values | Sort-Object shortName)

    return [ordered]@{
        '$schema'     = "./schemas/detected_catalog.schema.json"
        schemaVersion = 1
        format        = "arcane-wilds.detected_catalog"
        modVersion    = "local-fallback"
        generatedAt   = [DateTime]::UtcNow.ToString("o")
        source        = "fallback"
        categories    = $sortedCats
        spells        = $sortedSpells
        vfx           = $sortedVfx
        sfx           = $sortedSfx
        montages      = $sortedMontages
    } | ConvertTo-Json -Depth 10
}

# Start HttpListener on the first free port starting at $Port
$listener = $null
$boundPort = $Port
for ($attempt = 0; $attempt -lt 20; $attempt++) {
    $tryPort = $Port + $attempt
    $candidate = New-Object System.Net.HttpListener
    $candidate.Prefixes.Add("http://127.0.0.1:$tryPort/")
    try {
        $candidate.Start()
        $listener = $candidate
        $boundPort = $tryPort
        break
    } catch {
        $candidate.Close()
    }
}

if (-not $listener) {
    throw "Could not bind local HTTP server on ports $Port..$($Port + 19)."
}

$url = "http://127.0.0.1:$boundPort/"
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host " Arcane Wilds Spell & Combo Editor" -ForegroundColor Cyan
Write-Host " URL      : $url" -ForegroundColor Green
Write-Host " Mod Dir  : $ModDir" -ForegroundColor Gray
Write-Host " User Dir : $UserDir" -ForegroundColor Yellow
Write-Host " Press Ctrl+C in this window to stop the editor server." -ForegroundColor DarkGray
Write-Host "==========================================================" -ForegroundColor Cyan

if (-not $NoBrowser) {
    Start-Process $url | Out-Null
}

try {
    while ($listener.IsListening) {
        $ctx = $listener.GetContext()
        $req = $ctx.Request
        $res = $ctx.Response

        try {
            $path = $req.Url.AbsolutePath
            $method = $req.HttpMethod.ToUpperInvariant()

            if ($path -eq "/api/status" -and $method -eq "GET") {
                $statusObj = [ordered]@{
                    ok             = $true
                    modDir         = $ModDir
                    userDir        = $UserDir
                    schemaVersions = [ordered]@{
                        custom_spells    = 1
                        combo_rules      = 1
                        detected_catalog = 1
                        bundle           = 1
                        user_spells      = 1
                        user_combos      = 1
                        user_quick_cast  = 1
                    }
                    files          = [ordered]@{
                        default_spells   = Get-FileMtimeIso (Join-Path $ModDir "custom_spells.json")
                        default_combos   = Get-FileMtimeIso (Join-Path $ModDir "combo_rules.json")
                        default_qc       = Get-FileMtimeIso (Join-Path $ModDir "quick_cast.txt")
                        detected_catalog = Get-FileMtimeIso (Join-Path $ModDir "detected_catalog.json")
                        user_spells      = Get-FileMtimeIso (Join-Path $UserDir "user_spells.json")
                        user_combos      = Get-FileMtimeIso (Join-Path $UserDir "user_combos.json")
                        user_quick_cast  = Get-FileMtimeIso (Join-Path $UserDir "user_quick_cast.json")
                    }
                }
                Write-JsonResponse $res 200 ($statusObj | ConvertTo-Json -Depth 6)
                continue
            }

            if ($path -eq "/api/defaults" -and $method -eq "GET") {
                $defSpPath = Join-Path $ModDir "custom_spells.json"
                $defCbPath = Join-Path $ModDir "combo_rules.json"
                $defQcPath = Join-Path $ModDir "quick_cast.txt"

                $defSpRaw = if (Test-Path -LiteralPath $defSpPath -PathType Leaf) { Get-Content -LiteralPath $defSpPath -Raw -Encoding UTF8 } else { '{"schemaVersion":1,"spells":{}}' }
                $defCbRaw = if (Test-Path -LiteralPath $defCbPath -PathType Leaf) { Get-Content -LiteralPath $defCbPath -Raw -Encoding UTF8 } else { '{"schemaVersion":1,"rules":[]}' }

                $qcBindings = @()
                if (Test-Path -LiteralPath $defQcPath -PathType Leaf) {
                    foreach ($line in (Get-Content -LiteralPath $defQcPath -Encoding UTF8)) {
                        $clean = $line.Trim()
                        if ($clean -eq "" -or $clean.StartsWith("#") -or $clean.StartsWith(";")) { continue }
                        $hIdx = $clean.IndexOf("#")
                        if ($hIdx -ge 0) { $clean = $clean.Substring(0, $hIdx).Trim() }
                        $eqIdx = $clean.IndexOf("=")
                        if ($eqIdx -le 0) { continue }
                        $lhs = $clean.Substring(0, $eqIdx).Trim()
                        $rhs = $clean.Substring($eqIdx + 1).Trim()
                        $mod = "BLOCK"
                        $keysPart = $lhs
                        if ($lhs -match '^([A-Za-z0-9_]+)\s*\+\s*(.+)$') {
                            $mod = $Matches[1].Trim().ToUpperInvariant()
                            $keysPart = $Matches[2].Trim()
                        }
                        if ($mod -in @("RMB", "MODIFIER", "MOD")) { $mod = "BLOCK" }
                        elseif ($mod -in @("OFF", "FALSE", "")) { $mod = "NONE" }
                        $keys = @($keysPart -split '[,|;]' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" })
                        if ($keys.Count -gt 0 -and $rhs -ne "") {
                            $qcBindings += [ordered]@{ enabled = $true; modifier = $mod; keys = $keys; target = $rhs }
                        }
                    }
                }

                $respObj = [ordered]@{
                    ok        = $true
                    spellsRaw = $defSpRaw
                    combosRaw = $defCbRaw
                    quickCast = $qcBindings
                }
                Write-JsonResponse $res 200 ($respObj | ConvertTo-Json -Depth 10)
                continue
            }

            if ($path -eq "/api/user/spells") {
                $uSpPath = Join-Path $UserDir "user_spells.json"
                if ($method -eq "GET") {
                    if (Test-Path -LiteralPath $uSpPath -PathType Leaf) {
                        Write-JsonResponse $res 200 (Get-Content -LiteralPath $uSpPath -Raw -Encoding UTF8)
                    } else {
                        Write-JsonResponse $res 200 '{"schemaVersion":1,"format":"arcane-wilds.user_spells","disabledDefaults":[],"spells":{}}'
                    }
                    continue
                } elseif ($method -eq "PUT" -or $method -eq "POST") {
                    $body = Read-RequestBody $req
                    Save-JsonAtomically -TargetPath $uSpPath -JsonText $body
                    $resp = [ordered]@{ ok = $true; path = $uSpPath; savedAt = [DateTime]::UtcNow.ToString("o") } | ConvertTo-Json
                    Write-JsonResponse $res 200 $resp
                    continue
                }
            }

            if ($path -eq "/api/user/combos") {
                $uCbPath = Join-Path $UserDir "user_combos.json"
                if ($method -eq "GET") {
                    if (Test-Path -LiteralPath $uCbPath -PathType Leaf) {
                        Write-JsonResponse $res 200 (Get-Content -LiteralPath $uCbPath -Raw -Encoding UTF8)
                    } else {
                        Write-JsonResponse $res 200 '{"schemaVersion":1,"format":"arcane-wilds.user_combos","disableAllDefaults":false,"disabledDefaultIds":[],"rules":[]}'
                    }
                    continue
                } elseif ($method -eq "PUT" -or $method -eq "POST") {
                    $body = Read-RequestBody $req
                    Save-JsonAtomically -TargetPath $uCbPath -JsonText $body
                    $resp = [ordered]@{ ok = $true; path = $uCbPath; savedAt = [DateTime]::UtcNow.ToString("o") } | ConvertTo-Json
                    Write-JsonResponse $res 200 $resp
                    continue
                }
            }

            if ($path -eq "/api/user/quickcast") {
                $uQcPath = Join-Path $UserDir "user_quick_cast.json"
                if ($method -eq "GET") {
                    if (Test-Path -LiteralPath $uQcPath -PathType Leaf) {
                        Write-JsonResponse $res 200 (Get-Content -LiteralPath $uQcPath -Raw -Encoding UTF8)
                    } else {
                        Write-JsonResponse $res 200 '{"schemaVersion":1,"format":"arcane-wilds.user_quick_cast","overrideDefaults":false,"bindings":[]}'
                    }
                    continue
                } elseif ($method -eq "PUT" -or $method -eq "POST") {
                    $body = Read-RequestBody $req
                    Save-JsonAtomically -TargetPath $uQcPath -JsonText $body
                    $resp = [ordered]@{ ok = $true; path = $uQcPath; savedAt = [DateTime]::UtcNow.ToString("o") } | ConvertTo-Json
                    Write-JsonResponse $res 200 $resp
                    continue
                } elseif ($method -eq "DELETE") {
                    if (Test-Path -LiteralPath $uQcPath -PathType Leaf) {
                        Remove-Item -LiteralPath $uQcPath -Force
                    }
                    Write-JsonResponse $res 200 '{"ok":true,"reset":true}'
                    continue
                }
            }

            if ($path -eq "/api/open-user-dir" -and $method -eq "POST") {
                Start-Process "explorer.exe" -ArgumentList "`"$UserDir`"" | Out-Null
                Write-JsonResponse $res 200 ([ordered]@{ ok = $true; path = $UserDir } | ConvertTo-Json)
                continue
            }

            if ($path -eq "/api/catalog" -and $method -eq "GET") {
                $catPath = Join-Path $ModDir "detected_catalog.json"
                if (Test-Path -LiteralPath $catPath -PathType Leaf) {
                    $raw = Get-Content -LiteralPath $catPath -Raw -Encoding UTF8
                    Write-JsonResponse $res 200 $raw
                } else {
                    $fallbackJson = Build-FallbackCatalog -BaseDir $ModDir
                    Write-JsonResponse $res 200 $fallbackJson
                }
                continue
            }

            if ($path -eq "/api/spells") {
                $spPath = Join-Path $ModDir "custom_spells.json"
                if ($method -eq "GET") {
                    if (Test-Path -LiteralPath $spPath -PathType Leaf) {
                        $raw = Get-Content -LiteralPath $spPath -Raw -Encoding UTF8
                        Write-JsonResponse $res 200 $raw
                    } else {
                        Write-JsonResponse $res 200 '{"$schema":"./schemas/custom_spells.schema.json","schemaVersion":1,"spells":{}}'
                    }
                    continue
                } elseif ($method -eq "PUT" -or $method -eq "POST") {
                    $body = Read-RequestBody $req
                    Save-JsonAtomically -TargetPath $spPath -JsonText $body
                    $resp = [ordered]@{ ok = $true; path = $spPath; savedAt = [DateTime]::UtcNow.ToString("o") } | ConvertTo-Json
                    Write-JsonResponse $res 200 $resp
                    continue
                }
            }

            if ($path -eq "/api/combos") {
                $cbPath = Join-Path $ModDir "combo_rules.json"
                if ($method -eq "GET") {
                    if (Test-Path -LiteralPath $cbPath -PathType Leaf) {
                        $raw = Get-Content -LiteralPath $cbPath -Raw -Encoding UTF8
                        Write-JsonResponse $res 200 $raw
                    } else {
                        Write-JsonResponse $res 200 '{"$schema":"./schemas/combo_rules.schema.json","schemaVersion":1,"rules":[]}'
                    }
                    continue
                } elseif ($method -eq "PUT" -or $method -eq "POST") {
                    $body = Read-RequestBody $req
                    Save-JsonAtomically -TargetPath $cbPath -JsonText $body
                    $resp = [ordered]@{ ok = $true; path = $cbPath; savedAt = [DateTime]::UtcNow.ToString("o") } | ConvertTo-Json
                    Write-JsonResponse $res 200 $resp
                    continue
                }
            }

            if ($path -eq "/api/export" -and $method -eq "POST") {
                $body = Read-RequestBody $req
                $payload = $body | ConvertFrom-Json
                $rawName = if ($payload.filename) { [string]$payload.filename } else { "arcane-wilds-export.json" }
                $safeName = [System.IO.Path]::GetFileName($rawName)
                $safeName = $safeName -replace '[^A-Za-z0-9._-]', '_'
                if (-not $safeName.EndsWith(".json", [System.StringComparison]::OrdinalIgnoreCase)) {
                    $safeName = "$safeName.json"
                }

                $exportsDir = Join-Path $UserDir "exports"
                if (-not (Test-Path -LiteralPath $exportsDir -PathType Container)) {
                    New-Item -ItemType Directory -Force -Path $exportsDir | Out-Null
                }
                $outPath = Join-Path $exportsDir $safeName

                $contentText = if ($payload.content -is [string]) {
                    $payload.content
                } else {
                    $payload.data | ConvertTo-Json -Depth 20
                }
                # Validate JSON before writing
                $null = $contentText | ConvertFrom-Json
                [System.IO.File]::WriteAllText($outPath, $contentText.TrimEnd() + "`n", (New-Object System.Text.UTF8Encoding($false)))

                $shouldOpen = ($payload.openExplorer -ne $false)
                if ($shouldOpen) {
                    Start-Process "explorer.exe" -ArgumentList "/select,`"$outPath`"" | Out-Null
                }

                $resp = [ordered]@{
                    ok           = $true
                    path         = $outPath
                    filename     = $safeName
                    openedFolder = $shouldOpen
                } | ConvertTo-Json
                Write-JsonResponse $res 200 $resp
                continue
            }

            # Static file serving from editor/
            if ($method -eq "GET") {
                $relPath = if ($path -eq "/" -or $path -eq "") { "index.html" } else { $path.TrimStart("/") }
                $relPath = $relPath -replace '/', '\'
                $candidatePath = [System.IO.Path]::GetFullPath((Join-Path $editorDir $relPath))
                if (-not $candidatePath.StartsWith($editorDir, [System.StringComparison]::OrdinalIgnoreCase)) {
                    Write-JsonResponse $res 403 '{"error":"Forbidden"}'
                    continue
                }
                if (Test-Path -LiteralPath $candidatePath -PathType Leaf) {
                    $ext = [System.IO.Path]::GetExtension($candidatePath).ToLowerInvariant()
                    $ct = if ($mimeTypes.ContainsKey($ext)) { $mimeTypes[$ext] } else { "application/octet-stream" }
                    $bytes = [System.IO.File]::ReadAllBytes($candidatePath)
                    $res.StatusCode = 200
                    $res.ContentType = $ct
                    $res.Headers["Cache-Control"] = "no-store"
                    $res.ContentLength64 = $bytes.Length
                    $res.OutputStream.Write($bytes, 0, $bytes.Length)
                    $res.OutputStream.Close()
                    continue
                }
            }

            Write-JsonResponse $res 404 '{"error":"Not Found"}'
        } catch {
            $errJson = [ordered]@{ ok = $false; error = $_.Exception.Message } | ConvertTo-Json
            try {
                Write-JsonResponse $res 500 $errJson
            } catch {
                # Ignore if stream already closed
            }
        }
    }
} finally {
    if ($listener) {
        $listener.Stop()
        $listener.Close()
    }
}
