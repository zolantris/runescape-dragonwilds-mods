-- ArcaneWilds - Offline Lua Unit & Regression Test Runner
-- Run via: lua arcane-wilds/tests/run_tests.lua (or .\mod.ps1 test arcane-wilds)
-- Options:
--   --no-coverage                 Disable Lua line coverage collection
--   --coverage-details            Print missed line ranges per script file
--   --lcov <path>                 Write standard LCOV report to <path>
--   --coverage-markdown <path>    Write Markdown coverage table to <path>
--   --min-coverage <percent>      Fail if total line coverage is below <percent>

local thisPath = debug.getinfo(1, "S").source:match("^@?(.*)$")
local testsDir = thisPath:match("^(.*)[\\/][^\\/]+$") or "."
local arcaneRoot = testsDir:match("^(.*)[\\/][^\\/]+$") or ".."
local modRoot = arcaneRoot .. "/ue4ss/Mods/ArcaneWilds"
local scriptsDir = modRoot .. "/Scripts"

_G.MOD_ROOT = modRoot
package.path = testsDir .. "/?.lua;" .. scriptsDir .. "/?.lua;" .. package.path

local opts = {
    coverage = true,
    showMissed = false,
    lcovPath = nil,
    markdownPath = nil,
    minCoverage = nil,
}

if type(arg) == "table" then
    local i = 1
    while i <= #arg do
        local tok = arg[i]
        if tok == "--no-coverage" then
            opts.coverage = false
        elseif tok == "--coverage-details" or tok == "--show-missed" then
            opts.showMissed = true
        elseif tok == "--lcov" and arg[i + 1] then
            opts.lcovPath = arg[i + 1]
            i = i + 1
        elseif tok == "--coverage-markdown" and arg[i + 1] then
            opts.markdownPath = arg[i + 1]
            i = i + 1
        elseif tok == "--min-coverage" and arg[i + 1] then
            local val = tonumber(arg[i + 1])
            if not val then
                io.stderr:write("Invalid --min-coverage value: " .. tostring(arg[i + 1]) .. "\n")
                os.exit(2)
            end
            opts.minCoverage = val
            i = i + 1
        end
        i = i + 1
    end
end

local Mock = require("ue4ss_mock")
Mock.InstallGlobals()

local T = require("test_harness")
local Coverage = require("coverage")

local collector = nil
if opts.coverage then
    collector = Coverage.New({
        sourceDir = scriptsDir,
        displayPrefix = "arcane-wilds/ue4ss/Mods/ArcaneWilds/Scripts",
    })
    collector:Start()
end

require("test_coverage")
require("test_json")
require("test_custom_spells")
require("test_combo_rules")
require("test_config_hotreload")
require("test_input_blocker")
require("test_overlap_and_lockon")
require("test_air4_fixes")

local coverageOk = true
if collector then
    collector:Stop()
    local report = collector:ComputeReport()
    print(Coverage.FormatConsoleReport(report, { showMissed = opts.showMissed }))

    if opts.lcovPath then
        local ok, err = Coverage.WriteFile(opts.lcovPath, Coverage.FormatLcov(report, "arcane-wilds"))
        if ok then
            print("LCOV report written to: " .. opts.lcovPath)
        else
            io.stderr:write("Failed to write LCOV report to " .. opts.lcovPath .. ": " .. tostring(err) .. "\n")
            coverageOk = false
        end
    end

    if opts.markdownPath then
        local ok, err = Coverage.WriteFile(opts.markdownPath, Coverage.FormatMarkdownReport(report))
        if ok then
            print("Markdown coverage summary written to: " .. opts.markdownPath)
        else
            io.stderr:write("Failed to write Markdown coverage summary to " .. opts.markdownPath .. ": " .. tostring(err) .. "\n")
            coverageOk = false
        end
    end

    if opts.minCoverage ~= nil and report.totalPct + 1e-9 < opts.minCoverage then
        print(string.format(
            "COVERAGE FAIL: total line coverage %.1f%% is below minimum threshold %.1f%%",
            report.totalPct, opts.minCoverage
        ))
        coverageOk = false
    end
end

local allPassed = T.Summary()
os.exit((allPassed and coverageOk) and 0 or 1)
