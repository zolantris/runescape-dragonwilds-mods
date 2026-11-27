-- ArcaneWilds - Zero-Dependency Lua 5.4 Line Coverage Collector & Reporter
-- Uses Lua's built-in debug.sethook("l") line hook and pure-Lua source analysis.
-- No LuaRocks, C extensions, or external dependencies required.

local Coverage = {}

local IS_WINDOWS = (package.config:sub(1, 1) == "\\")

local function NormalizePath(p)
    if type(p) ~= "string" then return "" end
    local s = p:gsub("^@", ""):gsub("\\", "/")
    -- Collapse repeated slashes
    s = s:gsub("/+", "/")
    -- Resolve "." and ".." path segments
    local prefix = ""
    if s:sub(1, 1) == "/" then
        prefix = "/"
        s = s:sub(2)
    elseif s:match("^[A-Za-z]:/") then
        prefix = s:sub(1, 3)
        s = s:sub(4)
    end
    local parts = {}
    for seg in s:gmatch("[^/]+") do
        if seg == "." then
            -- skip
        elseif seg == ".." then
            if #parts > 0 and parts[#parts] ~= ".." then
                table.remove(parts)
            elseif prefix == "" then
                table.insert(parts, "..")
            end
        else
            table.insert(parts, seg)
        end
    end
    return prefix .. table.concat(parts, "/")
end

local function CanonicalKey(p)
    local norm = NormalizePath(p)
    if IS_WINDOWS then
        return norm:lower()
    end
    return norm
end

-- Discover all *.lua files directly inside sourceDir without external dependencies.
function Coverage.DiscoverLuaFiles(sourceDir)
    local files = {}
    local seen = {}
    local cmd
    if IS_WINDOWS then
        local winDir = sourceDir:gsub("/", "\\")
        cmd = string.format('dir /b /a-d "%s\\*.lua" 2>nul', winDir)
    else
        cmd = string.format('ls -1 "%s"/*.lua 2>/dev/null', sourceDir)
    end

    local ok, pipe = pcall(io.popen, cmd, "r")
    if ok and pipe then
        for line in pipe:lines() do
            local name = line:match("([^\\/]+%.lua)%s*$")
            if name and not seen[name] then
                seen[name] = true
                table.insert(files, name)
            end
        end
        pipe:close()
    end
    table.sort(files)
    return files
end

-- Helper: detect Lua long-bracket opener `[=*[` starting at index `pos` in string `s`.
-- Returns (eqCount, endOfOpenerIndex) or nil.
local function MatchLongBracketOpen(s, pos)
    if s:sub(pos, pos) ~= "[" then return nil end
    local i = pos + 1
    while s:sub(i, i) == "=" do
        i = i + 1
    end
    if s:sub(i, i) == "[" then
        return (i - pos - 1), i
    end
    return nil
end

-- Helper: find Lua long-bracket closer `]=*]` with exact `eqCount` starting at `pos`.
-- Returns index of final `]` or nil.
local function FindLongBracketClose(s, pos, eqCount)
    local closer = "]" .. string.rep("=", eqCount) .. "]"
    local _, closeEnd = s:find(closer, pos, true)
    return closeEnd
end

-- Non-executable pure structural/closing lines that Lua's VM does not execute as statements.
local NON_EXEC_EXACT = {
    ["end"] = true,
    ["else"] = true,
    ["repeat"] = true,
    ["do"] = true,
    ["then"] = true,
    ["{"] = true,
    ["}"] = true,
    ["},"] = true,
    ["};"] = true,
    [")"] = true,
    ["),"] = true,
    [");"] = true,
    ["end)"] = true,
    ["end,"] = true,
    ["end;"] = true,
    ["end))"] = true,
    ["end),"] = true,
    ["end);"] = true,
    ["})"] = true,
    ["}),"] = true,
    ["});"] = true,
}

local function IsNonExecutableCodeFragment(code)
    local trimmed = code:match("^%s*(.-)%s*$")
    if trimmed == "" then return true end
    if NON_EXEC_EXACT[trimmed] then return true end
    -- Pure closing brackets / delimiters / `end` combinations (e.g. `end,`, `}},`, `)))`)
    if trimmed:match("^[}%)%;%,%s]+$") then return true end
    -- Pure goto label `::label::`
    if trimmed:match("^::[A-Za-z_][A-Za-z0-9_]*::$") then return true end
    return false
end

-- Analyze Lua source text and return a sorted array of executable line numbers
-- plus a set map `execSet[lineNo] = true`.
-- Any line present in `hitMap` with count > 0 is always treated as executable.
function Coverage.AnalyzeExecutableLines(sourceText, hitMap)
    local execSet = {}
    local lineNo = 0
    local inLongComment = nil -- number of '=' signs if inside --[=[ ... ]=]
    local inLongString = nil  -- number of '=' signs if inside [=[ ... ]=]

    -- Iterate line by line (preserving trailing empty line behavior cleanly)
    for rawLine in (sourceText .. "\n"):gmatch("(.-)\r?\n") do
        lineNo = lineNo + 1
        local len = #rawLine
        local i = 1
        local codeParts = {}

        while i <= len do
            if inLongComment ~= nil then
                local closeEnd = FindLongBracketClose(rawLine, i, inLongComment)
                if closeEnd then
                    inLongComment = nil
                    i = closeEnd + 1
                else
                    i = len + 1
                end
            elseif inLongString ~= nil then
                local closeEnd = FindLongBracketClose(rawLine, i, inLongString)
                if closeEnd then
                    inLongString = nil
                    i = closeEnd + 1
                else
                    i = len + 1
                end
            else
                local ch = rawLine:sub(i, i)
                if ch == "-" and rawLine:sub(i + 1, i + 1) == "-" then
                    -- Comment: check for long comment `--[=[`
                    local eqCount, openEnd = MatchLongBracketOpen(rawLine, i + 2)
                    if eqCount ~= nil then
                        local closeEnd = FindLongBracketClose(rawLine, openEnd + 1, eqCount)
                        if closeEnd then
                            i = closeEnd + 1
                        else
                            inLongComment = eqCount
                            i = len + 1
                        end
                    else
                        -- Single-line comment to end of line
                        i = len + 1
                    end
                elseif ch == '"' or ch == "'" then
                    -- Quoted string literal (part of executable code on this line)
                    local quote = ch
                    local startIdx = i
                    i = i + 1
                    while i <= len do
                        local c = rawLine:sub(i, i)
                        if c == "\\" then
                            i = i + 2
                        elseif c == quote then
                            i = i + 1
                            break
                        else
                            i = i + 1
                        end
                    end
                    table.insert(codeParts, rawLine:sub(startIdx, i - 1))
                elseif ch == "[" then
                    local eqCount, openEnd = MatchLongBracketOpen(rawLine, i)
                    if eqCount ~= nil then
                        -- Opening of long string is part of an expression on this line
                        table.insert(codeParts, "[[str]]")
                        local closeEnd = FindLongBracketClose(rawLine, openEnd + 1, eqCount)
                        if closeEnd then
                            i = closeEnd + 1
                        else
                            inLongString = eqCount
                            i = len + 1
                        end
                    else
                        table.insert(codeParts, ch)
                        i = i + 1
                    end
                else
                    table.insert(codeParts, ch)
                    i = i + 1
                end
            end
        end

        local code = table.concat(codeParts)
        if not IsNonExecutableCodeFragment(code) then
            execSet[lineNo] = true
        end
    end

    -- Guarantee invariant: any line actually hit at runtime counts as executable.
    if type(hitMap) == "table" then
        for ln, count in pairs(hitMap) do
            if type(ln) == "number" and count > 0 and ln >= 1 and ln <= lineNo then
                execSet[ln] = true
            end
        end
    end

    local execLines = {}
    for ln in pairs(execSet) do
        table.insert(execLines, ln)
    end
    table.sort(execLines)
    return execLines, execSet
end

-- Compress a sorted list of line numbers into compact ranges, e.g. "12-15, 20, 31-33".
function Coverage.FormatLineRanges(lines, maxRanges)
    if not lines or #lines == 0 then return "" end
    local ranges = {}
    local startLn = lines[1]
    local prevLn = lines[1]

    for i = 2, #lines do
        local cur = lines[i]
        if cur == prevLn + 1 then
            prevLn = cur
        else
            table.insert(ranges, startLn == prevLn and tostring(startLn) or (startLn .. "-" .. prevLn))
            startLn = cur
            prevLn = cur
        end
    end
    table.insert(ranges, startLn == prevLn and tostring(startLn) or (startLn .. "-" .. prevLn))

    if maxRanges and #ranges > maxRanges then
        local shown = {}
        for i = 1, maxRanges do
            shown[i] = ranges[i]
        end
        return table.concat(shown, ", ") .. string.format(" (+%d more)", #ranges - maxRanges)
    end
    return table.concat(ranges, ", ")
end

-- Create a new independent coverage collector instance.
function Coverage.New(opts)
    opts = opts or {}
    local sourceDir = NormalizePath(opts.sourceDir or ".")
    if sourceDir:sub(-1) == "/" then
        sourceDir = sourceDir:sub(1, -2)
    end
    local sourceDirKey = CanonicalKey(sourceDir)
    local sourceDirPrefix = sourceDirKey .. "/"
    local displayPrefix = opts.displayPrefix or sourceDir

    local self = {
        sourceDir = sourceDir,
        sourceDirKey = sourceDirKey,
        sourceDirPrefix = sourceDirPrefix,
        displayPrefix = displayPrefix,
        files = {},         -- key -> { name = "foo.lua", fullPath = "...", hits = {} }
        sourceCache = {},   -- raw debug.getinfo(2, "S").source -> key or false
        active = false,
        prevHook = nil,
        prevMask = nil,
        prevCount = nil,
    }

    local function RegisterFile(fullPath, relName)
        local key = CanonicalKey(fullPath)
        if not self.files[key] then
            self.files[key] = {
                name = relName,
                fullPath = NormalizePath(fullPath),
                hits = {},
            }
        end
        return key
    end

    -- Pre-register scripts so untested (0% coverage) files always appear in reports.
    local discovered = opts.files or Coverage.DiscoverLuaFiles(sourceDir)
    for _, relName in ipairs(discovered) do
        local normRel = relName:gsub("\\", "/")
        RegisterFile(sourceDir .. "/" .. normRel, normRel)
    end

    local function ResolveSource(rawSource)
        local cached = self.sourceCache[rawSource]
        if cached ~= nil then
            return cached
        end
        if type(rawSource) ~= "string" or rawSource:sub(1, 1) ~= "@" then
            self.sourceCache[rawSource] = false
            return false
        end
        local norm = NormalizePath(rawSource)
        local key = CanonicalKey(norm)
        if key:sub(1, #self.sourceDirPrefix) == self.sourceDirPrefix then
            local relName = norm:sub(#self.sourceDir + 2)
            RegisterFile(norm, relName)
            self.sourceCache[rawSource] = key
            return key
        end
        -- Fallback: match by basename if path came through relative require path
        local baseName = norm:match("([^/]+%.lua)$")
        if baseName then
            local candidateKey = CanonicalKey(self.sourceDir .. "/" .. baseName)
            if self.files[candidateKey] then
                -- Ensure it actually lives in a Scripts/ directory (avoid colliding with tests/)
                if key:find("/scripts/" .. baseName:lower(), 1, true)
                    or (not IS_WINDOWS and norm:find("/Scripts/" .. baseName, 1, true))
                then
                    self.sourceCache[rawSource] = candidateKey
                    return candidateKey
                end
            end
        end
        self.sourceCache[rawSource] = false
        return false
    end

    local function OnLine(_, lineNo)
        local info = debug.getinfo(2, "S")
        if not info then return end
        local key = ResolveSource(info.source)
        if not key then return end
        local entry = self.files[key]
        if entry and lineNo then
            entry.hits[lineNo] = (entry.hits[lineNo] or 0) + 1
        end
    end

    function self:Start()
        if self.active then return end
        self.prevHook, self.prevMask, self.prevCount = debug.gethook()
        self.active = true
        debug.sethook(OnLine, "l")
    end

    function self:Stop()
        if not self.active then return end
        self.active = false
        if self.prevHook then
            debug.sethook(self.prevHook, self.prevMask, self.prevCount)
        else
            debug.sethook()
        end
        self.prevHook, self.prevMask, self.prevCount = nil, nil, nil
    end

    function self:ComputeReport()
        local fileReports = {}
        local totalHit = 0
        local totalExec = 0

        for _, entry in pairs(self.files) do
            local f = io.open(entry.fullPath, "r")
            if f then
                local content = f:read("*a")
                f:close()
                local execLines = Coverage.AnalyzeExecutableLines(content, entry.hits)
                local hitCount = 0
                local missedLines = {}
                local lineHits = {}

                for _, ln in ipairs(execLines) do
                    local c = entry.hits[ln] or 0
                    lineHits[ln] = c
                    if c > 0 then
                        hitCount = hitCount + 1
                    else
                        table.insert(missedLines, ln)
                    end
                end

                local execCount = #execLines
                local missCount = execCount - hitCount
                local pct = (execCount > 0) and (hitCount * 100.0 / execCount) or 100.0

                totalHit = totalHit + hitCount
                totalExec = totalExec + execCount

                table.insert(fileReports, {
                    name = entry.name,
                    fullPath = entry.fullPath,
                    hit = hitCount,
                    missed = missCount,
                    total = execCount,
                    pct = pct,
                    execLines = execLines,
                    missedLines = missedLines,
                    lineHits = lineHits,
                })
            end
        end

        table.sort(fileReports, function(a, b) return a.name < b.name end)

        local totalMissed = totalExec - totalHit
        local totalPct = (totalExec > 0) and (totalHit * 100.0 / totalExec) or 100.0

        return {
            sourceDir = self.sourceDir,
            displayPrefix = self.displayPrefix,
            files = fileReports,
            totalHit = totalHit,
            totalMissed = totalMissed,
            totalExec = totalExec,
            totalPct = totalPct,
        }
    end

    return self
end

-- Format console report string.
function Coverage.FormatConsoleReport(report, opts)
    opts = opts or {}
    local lines = {}
    local sep = string.rep("=", 66)
    local dash = string.rep("-", 66)

    table.insert(lines, "")
    table.insert(lines, sep)
    table.insert(lines, "Lua Line Coverage (" .. tostring(report.displayPrefix or report.sourceDir) .. ")")
    table.insert(lines, sep)
    table.insert(lines, string.format("%-30s %7s %7s %7s %9s", "File", "Hit", "Missed", "Total", "Coverage"))
    table.insert(lines, dash)

    for _, fr in ipairs(report.files) do
        table.insert(lines, string.format(
            "%-30s %7d %7d %7d %8.1f%%",
            fr.name, fr.hit, fr.missed, fr.total, fr.pct
        ))
        if opts.showMissed and #fr.missedLines > 0 then
            local rangeStr = Coverage.FormatLineRanges(fr.missedLines, opts.maxMissedRanges or 12)
            table.insert(lines, "  missed: " .. rangeStr)
        end
    end

    table.insert(lines, dash)
    table.insert(lines, string.format(
        "%-30s %7d %7d %7d %8.1f%%",
        "TOTAL", report.totalHit, report.totalMissed, report.totalExec, report.totalPct
    ))
    table.insert(lines, sep)
    return table.concat(lines, "\n")
end

-- Format GitHub-flavored Markdown report (ideal for CI $GITHUB_STEP_SUMMARY).
function Coverage.FormatMarkdownReport(report)
    local lines = {}
    table.insert(lines, "### Lua Line Coverage")
    table.insert(lines, "")
    table.insert(lines, "| File | Hit | Missed | Total | Coverage |")
    table.insert(lines, "| :--- | ---: | ---: | ---: | ---: |")
    for _, fr in ipairs(report.files) do
        table.insert(lines, string.format(
            "| `%s` | %d | %d | %d | %.1f%% |",
            fr.name, fr.hit, fr.missed, fr.total, fr.pct
        ))
    end
    table.insert(lines, string.format(
        "| **TOTAL** | **%d** | **%d** | **%d** | **%.1f%%** |",
        report.totalHit, report.totalMissed, report.totalExec, report.totalPct
    ))
    table.insert(lines, "")
    return table.concat(lines, "\n")
end

-- Format standard LCOV coverage file contents.
function Coverage.FormatLcov(report, testName)
    local lines = {}
    local tn = testName or "arcane-wilds"
    for _, fr in ipairs(report.files) do
        table.insert(lines, "TN:" .. tn)
        table.insert(lines, "SF:" .. fr.fullPath)
        for _, ln in ipairs(fr.execLines) do
            table.insert(lines, string.format("DA:%d,%d", ln, fr.lineHits[ln] or 0))
        end
        table.insert(lines, "LF:" .. tostring(fr.total))
        table.insert(lines, "LH:" .. tostring(fr.hit))
        table.insert(lines, "end_of_record")
    end
    return table.concat(lines, "\n") .. "\n"
end

function Coverage.WriteFile(path, content)
    local f, err = io.open(path, "w")
    if not f then
        return false, err
    end
    f:write(content)
    f:close()
    return true
end

return Coverage
