-- ArcaneWilds - Zero-Dependency Lua Unit Test Harness

local T = {
    passed = 0,
    failed = 0,
    failures = {},
    currentSuite = ""
}

local function ValueStr(v)
    if type(v) == "string" then
        return string.format("%q", v)
    end
    return tostring(v)
end

function T.Suite(name, fn)
    T.currentSuite = name
    print("\n[" .. name .. "]")
    fn()
end

function T.Test(name, fn)
    local ok, err = pcall(fn)
    if ok then
        T.passed = T.passed + 1
        print("  PASS  " .. name)
    else
        T.failed = T.failed + 1
        local fullLabel = T.currentSuite .. " :: " .. name
        table.insert(T.failures, { name = fullLabel, err = tostring(err) })
        print("  FAIL  " .. name)
        print("        " .. tostring(err))
    end
end

function T.AssertTrue(cond, msg)
    if not cond then
        error(msg or "expected condition to be truthy, got " .. ValueStr(cond), 2)
    end
end

function T.AssertFalse(cond, msg)
    if cond then
        error(msg or "expected condition to be falsy, got " .. ValueStr(cond), 2)
    end
end

function T.AssertNil(val, msg)
    if val ~= nil then
        error((msg and (msg .. ": ") or "") .. "expected nil, got " .. ValueStr(val), 2)
    end
end

function T.AssertNotNil(val, msg)
    if val == nil then
        error((msg and (msg .. ": ") or "") .. "expected non-nil value", 2)
    end
end

function T.AssertEq(actual, expected, msg)
    if actual ~= expected then
        error(string.format("%sexpected %s, got %s",
            msg and (msg .. ": ") or "", ValueStr(expected), ValueStr(actual)), 2)
    end
end

function T.AssertNear(actual, expected, eps, msg)
    eps = eps or 1e-4
    if type(actual) ~= "number" or type(expected) ~= "number" or math.abs(actual - expected) > eps then
        error(string.format("%sexpected ~%s (+/- %s), got %s",
            msg and (msg .. ": ") or "", tostring(expected), tostring(eps), ValueStr(actual)), 2)
    end
end

function T.AssertContains(str, substr, msg)
    if type(str) ~= "string" or not str:find(substr, 1, true) then
        error(string.format("%sexpected %s to contain %s",
            msg and (msg .. ": ") or "", ValueStr(str), ValueStr(substr)), 2)
    end
end

function T.Summary()
    print(string.format("\n========================================"))
    print(string.format("Tests: %d passed, %d failed, %d total", T.passed, T.failed, T.passed + T.failed))
    if #T.failures > 0 then
        print("Failures:")
        for _, f in ipairs(T.failures) do
            print("  - " .. f.name .. "\n      " .. f.err)
        end
    end
    print(string.format("========================================"))
    return T.failed == 0
end

return T
