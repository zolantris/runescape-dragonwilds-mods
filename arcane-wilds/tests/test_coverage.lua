-- Unit tests for tests/coverage.lua (line classification, hook collection, LCOV & summary formatting)

local T = require("test_harness")
local Coverage = require("coverage")

T.Suite("coverage.lua", function()
    T.Test("AnalyzeExecutableLines ignores comments, long comments, blank lines, and pure closing tokens", function()
        local src = table.concat({
            "-- Header comment",
            "",
            "--[[",
            "  Multi-line block comment",
            "  local ignored = 123",
            "]]",
            "local M = {",
            "    value = 1,",
            "}",
            "function M.Compute(x)",
            "    if x > 0 then",
            "        return x * 2 -- inline comment",
            "    else",
            "        return 0",
            "    end",
            "end",
            "return M",
        }, "\n")

        local execLines, execSet = Coverage.AnalyzeExecutableLines(src)
        -- Non-executable lines: 1 (comment), 2 (blank), 3-6 (long comment), 9 (}), 13 (else), 15 (end), 16 (end)
        T.AssertNil(execSet[1], "single-line comment must not be executable")
        T.AssertNil(execSet[2], "blank line must not be executable")
        T.AssertNil(execSet[3], "long comment start must not be executable")
        T.AssertNil(execSet[5], "long comment body must not be executable")
        T.AssertNil(execSet[6], "long comment end must not be executable")
        T.AssertNil(execSet[9], "pure closing brace must not be executable")
        T.AssertNil(execSet[13], "pure else must not be executable")
        T.AssertNil(execSet[15], "pure end must not be executable")
        T.AssertNil(execSet[16], "pure end must not be executable")

        -- Executable lines: 7, 8, 10, 11, 12, 14, 17
        T.AssertTrue(execSet[7], "table opener assignment is executable")
        T.AssertTrue(execSet[8], "table field is executable")
        T.AssertTrue(execSet[10], "function declaration is executable")
        T.AssertTrue(execSet[11], "if condition is executable")
        T.AssertTrue(execSet[12], "return with inline comment is executable")
        T.AssertTrue(execSet[14], "else branch return is executable")
        T.AssertTrue(execSet[17], "module return is executable")
        T.AssertEq(#execLines, 7)
    end)

    T.Test("AnalyzeExecutableLines handles strings containing --, multi-line strings, and runtime hit invariant", function()
        local src = table.concat({
            'local s = "not -- a comment"',
            "local multi = [=[",
            "  line inside long string",
            "  still inside",
            "]=]",
            "local y = 1",
            "end", -- even if syntactically structural, a recorded hit keeps invariant hit <= exec
        }, "\n")

        local _, execSet = Coverage.AnalyzeExecutableLines(src, { [7] = 1 })
        T.AssertTrue(execSet[1], "string containing -- must stay executable")
        T.AssertTrue(execSet[2], "opening line of long string assignment must be executable")
        T.AssertNil(execSet[3], "interior of long string must not be executable")
        T.AssertNil(execSet[4], "interior of long string must not be executable")
        T.AssertNil(execSet[5], "pure long string closer must not be executable")
        T.AssertTrue(execSet[6], "statement after long string must be executable")
        T.AssertTrue(execSet[7], "hit line must always be counted as executable")
    end)

    T.Test("FormatLineRanges compresses consecutive lines and truncates when over maxRanges", function()
        T.AssertEq(Coverage.FormatLineRanges({}), "")
        T.AssertEq(Coverage.FormatLineRanges({ 5 }), "5")
        T.AssertEq(Coverage.FormatLineRanges({ 1, 2, 3, 7, 10, 11 }), "1-3, 7, 10-11")
        T.AssertEq(Coverage.FormatLineRanges({ 1, 3, 5, 7 }, 2), "1, 3 (+2 more)")
    end)

    T.Test("tracks executed vs missed lines in an isolated temp script and restores previous debug hook", function()
        local base = os.getenv("TEMP") or os.getenv("TMP") or "."
        local tempName = "arcanewilds_cov_sample.lua"
        local tempPath = base .. "/" .. tempName
        local sampleSource = table.concat({
            "-- sample module",
            "local S = {}",
            "function S.Branch(flag)",
            "    if flag then",
            "        return 1",
            "    else",
            "        return 2",
            "    end",
            "end",
            "return S",
        }, "\n")

        local f, err = io.open(tempPath, "w")
        T.AssertNotNil(f, "failed to create temp script: " .. tostring(err))
        f:write(sampleSource)
        f:close()

        local prevHookBefore = debug.gethook()
        local okRun, errRun = pcall(function()
            local cov = Coverage.New({
                sourceDir = base,
                files = { tempName },
            })
            cov:Start()
            local chunk, loadErr = loadfile(tempPath)
            T.AssertNil(loadErr)
            local mod = chunk()
            T.AssertEq(mod.Branch(true), 1)
            cov:Stop()

            local report = cov:ComputeReport()
            T.AssertEq(#report.files, 1)
            local fr = report.files[1]
            T.AssertEq(fr.name, tempName)
            T.AssertEq(fr.missed, 1, "only the unexecuted else branch (line 7) should be missed")
            T.AssertEq(fr.missedLines[1], 7)
            T.AssertTrue(fr.hit > 0)
            T.AssertEq(fr.hit + fr.missed, fr.total)

            local lcov = Coverage.FormatLcov(report, "unit")
            T.AssertContains(lcov, "TN:unit")
            T.AssertContains(lcov, "DA:5,1")
            T.AssertContains(lcov, "DA:7,0")
            T.AssertContains(lcov, "LF:" .. tostring(fr.total))
            T.AssertContains(lcov, "LH:" .. tostring(fr.hit))
            T.AssertContains(lcov, "end_of_record")

            local md = Coverage.FormatMarkdownReport(report)
            T.AssertContains(md, "| `" .. tempName .. "` |")
            T.AssertContains(md, "| **TOTAL** |")
        end)

        pcall(os.remove, tempPath)
        T.AssertEq(debug.gethook(), prevHookBefore, "Coverage:Stop must restore outer debug hook")
        if not okRun then error(errRun) end
    end)
end)
