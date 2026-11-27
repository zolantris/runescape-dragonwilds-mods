-- ArcaneWilds - Offline Lua Unit & Regression Test Runner
-- Run via: lua arcane-wilds/tests/run_tests.lua (or .\mod.ps1 test arcane-wilds)

local thisPath = debug.getinfo(1, "S").source:match("^@?(.*)$")
local testsDir = thisPath:match("^(.*)[\\/][^\\/]+$") or "."
local arcaneRoot = testsDir:match("^(.*)[\\/][^\\/]+$") or ".."
local modRoot = arcaneRoot .. "/ue4ss/Mods/ArcaneWilds"
local scriptsDir = modRoot .. "/Scripts"

_G.MOD_ROOT = modRoot
package.path = testsDir .. "/?.lua;" .. scriptsDir .. "/?.lua;" .. package.path

local Mock = require("ue4ss_mock")
Mock.InstallGlobals()

local T = require("test_harness")

require("test_json")
require("test_custom_spells")
require("test_combo_rules")
require("test_config_hotreload")
require("test_input_blocker")
require("test_overlap_and_lockon")
require("test_air4_fixes")

local allPassed = T.Summary()
os.exit(allPassed and 0 or 1)
