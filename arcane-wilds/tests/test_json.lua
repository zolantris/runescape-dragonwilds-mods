-- Tests for Scripts/json.lua (JSON + JSONC decoding, error locations, and round-trip encoding)

local T = require("test_harness")
local Json = require("json")

T.Suite("json.lua", function()
    T.Test("decodes standard nested objects, arrays, numbers, booleans, and null", function()
        local raw = [[{
            "str": "hello \"world\"\nline2",
            "int": 42,
            "neg": -3.14,
            "exp": 1.5e2,
            "flagTrue": true,
            "flagFalse": false,
            "empty": null,
            "arr": [1, "two", {"three": 3}]
        }]]
        local val, err = Json.Decode(raw)
        T.AssertNil(err)
        T.AssertEq(val.str, 'hello "world"\nline2')
        T.AssertEq(val.int, 42)
        T.AssertNear(val.neg, -3.14, 1e-6)
        T.AssertNear(val.exp, 150, 1e-6)
        T.AssertEq(val.flagTrue, true)
        T.AssertEq(val.flagFalse, false)
        T.AssertNil(val.empty)
        T.AssertEq(#val.arr, 3)
        T.AssertEq(val.arr[1], 1)
        T.AssertEq(val.arr[2], "two")
        T.AssertEq(val.arr[3].three, 3)
    end)

    T.Test("supports JSONC line comments, block comments, trailing commas, and UTF-8 BOM", function()
        local raw = "\239\187\191" .. [[
        // Top comment
        {
            /* block
               comment */
            "a": [1, 2, 3, ], // trailing comma in array
            "b": "ok", // trailing comma in object
        }
        ]]
        local val, err = Json.Decode(raw)
        T.AssertNil(err)
        T.AssertEq(#val.a, 3)
        T.AssertEq(val.a[3], 3)
        T.AssertEq(val.b, "ok")
    end)

    T.Test("decodes unicode escapes including UTF-16 surrogate pairs", function()
        local val, err = Json.Decode('{"arrow": "\\u2192", "spark": "\\uD83D\\uDD25"}')
        T.AssertNil(err)
        T.AssertEq(val.arrow, "\226\134\146")
        T.AssertEq(val.spark, "\240\159\148\165")
    end)

    T.Test("reports line and column on syntax errors without throwing", function()
        local raw = "{\n  \"a\": 1,\n  \"b\": [1, 2\n}\n"
        local val, err = Json.Decode(raw)
        T.AssertNil(val)
        T.AssertNotNil(err)
        T.AssertContains(err, "line 4")
    end)

    T.Test("rejects unterminated string and trailing garbage", function()
        local v1, e1 = Json.Decode('{"a": "unterminated}')
        T.AssertNil(v1)
        T.AssertContains(e1, "unterminated string")

        local v2, e2 = Json.Decode('{"a": 1} extra')
        T.AssertNil(v2)
        T.AssertContains(e2, "unexpected trailing token")
    end)

    T.Test("LooksLikeJson distinguishes JSON/JSONC from INI/DSL text", function()
        T.AssertTrue(Json.LooksLikeJson('{"spells":{}}'))
        T.AssertTrue(Json.LooksLikeJson('\239\187\191 // comment\n  [1, 2]'))
        T.AssertFalse(Json.LooksLikeJson('[FlamesOfZamorak]\nBaseSpell = Foo'))
        T.AssertFalse(Json.LooksLikeJson('Air@bolt:1.5 -> SaradominGodsword:1 :5;'))
    end)

    T.Test("encodes and round-trips Lua tables cleanly", function()
        local orig = {
            name = "SaradominStrike",
            damage = { 65, 125 },
            enabled = true,
            nested = { range = 700, cone = 45 }
        }
        local encoded, encErr = Json.Encode(orig, { indent = 2 })
        T.AssertNil(encErr)
        local decoded, decErr = Json.Decode(encoded)
        T.AssertNil(decErr)
        T.AssertEq(decoded.name, "SaradominStrike")
        T.AssertEq(decoded.damage[1], 65)
        T.AssertEq(decoded.damage[2], 125)
        T.AssertEq(decoded.enabled, true)
        T.AssertEq(decoded.nested.range, 700)
    end)
end)
