-- ArcaneWilds - Pure Lua JSON / JSONC Parser & Serializer
-- Supports standard JSON plus player-friendly JSONC:
--   * UTF-8 BOM stripping (Windows Notepad / PowerShell safe)
--   * Single-line (//) and block (/* ... */) comments
--   * Trailing commas in objects and arrays
--   * Exact line & column error reporting (never throws uncaught errors from decode)

local Json = {}

local function ComputeLineCol(str, pos)
    local line = 1
    local lastNl = 0
    local i = 1
    while i < pos do
        local nl = str:find("\n", i, true)
        if not nl or nl >= pos then break end
        line = line + 1
        lastNl = nl
        i = nl + 1
    end
    return line, (pos - lastNl)
end

local function FormatError(str, pos, msg)
    local line, col = ComputeLineCol(str, pos)
    return string.format("line %d, col %d: %s", line, col, tostring(msg))
end

local function CodepointToUtf8(cp)
    if cp < 0 or cp > 0x10FFFF then
        return "?"
    elseif cp <= 0x7F then
        return string.char(cp)
    elseif cp <= 0x7FF then
        return string.char(
            0xC0 + math.floor(cp / 0x40),
            0x80 + (cp % 0x40)
        )
    elseif cp <= 0xFFFF then
        return string.char(
            0xE0 + math.floor(cp / 0x1000),
            0x80 + (math.floor(cp / 0x40) % 0x40),
            0x80 + (cp % 0x40)
        )
    else
        return string.char(
            0xF0 + math.floor(cp / 0x40000),
            0x80 + (math.floor(cp / 0x1000) % 0x40),
            0x80 + (math.floor(cp / 0x40) % 0x40),
            0x80 + (cp % 0x40)
        )
    end
end

local ESCAPE_MAP = {
    ['"']  = '"',
    ["\\"] = "\\",
    ["/"]  = "/",
    ["b"]  = "\b",
    ["f"]  = "\f",
    ["n"]  = "\n",
    ["r"]  = "\r",
    ["t"]  = "\t"
}

local function SkipWhitespaceAndComments(str, pos)
    local len = #str
    while pos <= len do
        local b = str:byte(pos)
        -- space, tab, LF, CR
        if b == 32 or b == 9 or b == 10 or b == 13 then
            pos = pos + 1
        elseif b == 47 then -- '/'
            local nextB = str:byte(pos + 1)
            if nextB == 47 then -- '//' line comment
                local nl = str:find("\n", pos + 2, true)
                if nl then
                    pos = nl + 1
                else
                    return len + 1, nil
                end
            elseif nextB == 42 then -- '/*' block comment
                local closePos = str:find("*/", pos + 2, true)
                if not closePos then
                    return nil, FormatError(str, pos, "unterminated block comment")
                end
                pos = closePos + 2
            else
                return pos, nil
            end
        else
            return pos, nil
        end
    end
    return pos, nil
end

local ParseValue

local function ParseString(str, pos)
    -- pos points at opening '"'
    local len = #str
    local i = pos + 1
    local chunks = {}
    local chunkStart = i

    while i <= len do
        local b = str:byte(i)
        if b == 34 then -- '"'
            if i > chunkStart then
                chunks[#chunks + 1] = str:sub(chunkStart, i - 1)
            end
            return table.concat(chunks), i + 1, nil
        elseif b == 92 then -- '\'
            if i > chunkStart then
                chunks[#chunks + 1] = str:sub(chunkStart, i - 1)
            end
            local esc = str:sub(i + 1, i + 1)
            if esc == "" then
                return nil, nil, FormatError(str, i, "unterminated escape sequence in string")
            end
            local mapped = ESCAPE_MAP[esc]
            if mapped then
                chunks[#chunks + 1] = mapped
                i = i + 2
            elseif esc == "u" then
                local hex = str:sub(i + 2, i + 5)
                if #hex < 4 or not hex:match("^[0-9a-fA-F]+$") then
                    return nil, nil, FormatError(str, i, "invalid unicode escape '\\u" .. hex .. "'")
                end
                local cp = tonumber(hex, 16)
                i = i + 6
                -- Handle UTF-16 surrogate pair
                if cp >= 0xD800 and cp <= 0xDBFF and str:sub(i, i + 1) == "\\u" then
                    local hex2 = str:sub(i + 2, i + 5)
                    local cp2 = (#hex2 == 4 and hex2:match("^[0-9a-fA-F]+$")) and tonumber(hex2, 16) or nil
                    if cp2 and cp2 >= 0xDC00 and cp2 <= 0xDFFF then
                        cp = 0x10000 + (cp - 0xD800) * 0x400 + (cp2 - 0xDC00)
                        i = i + 6
                    end
                end
                chunks[#chunks + 1] = CodepointToUtf8(cp)
            else
                return nil, nil, FormatError(str, i, "invalid escape character '\\" .. esc .. "'")
            end
            chunkStart = i
        elseif b < 32 then
            return nil, nil, FormatError(str, i, "unescaped control character in string")
        else
            i = i + 1
        end
    end

    return nil, nil, FormatError(str, pos, "unterminated string")
end

local function ParseNumber(str, pos)
    local numStr = str:match("^%-?%d+%.?%d*[eE]?[%+%-]?%d*", pos)
    if not numStr or numStr == "" then
        return nil, nil, FormatError(str, pos, "invalid number")
    end
    -- Strict JSON number shape validation (reject leading zeros like 01, trailing dot like 1., etc.)
    local check = numStr
    if check:sub(1, 1) == "-" then check = check:sub(2) end
    if check:match("^0%d") then
        return nil, nil, FormatError(str, pos, "leading zeros not allowed in number '" .. numStr .. "'")
    end
    if check:match("%.$") or check:match("[eE][%+%-]?$") then
        return nil, nil, FormatError(str, pos, "malformed number '" .. numStr .. "'")
    end
    local n = tonumber(numStr)
    if n == nil then
        return nil, nil, FormatError(str, pos, "invalid number '" .. numStr .. "'")
    end
    return n, pos + #numStr, nil
end

local function ParseArray(str, pos, depth)
    if depth > 64 then
        return nil, nil, FormatError(str, pos, "maximum nesting depth exceeded")
    end
    local arr = {}
    local nextPos, err = SkipWhitespaceAndComments(str, pos + 1)
    if err then return nil, nil, err end

    if str:byte(nextPos) == 93 then -- ']'
        return arr, nextPos + 1, nil
    end

    local idx = 1
    while true do
        local val, afterVal, vErr = ParseValue(str, nextPos, depth + 1)
        if vErr then return nil, nil, vErr end
        arr[idx] = val
        idx = idx + 1

        nextPos, err = SkipWhitespaceAndComments(str, afterVal)
        if err then return nil, nil, err end

        local b = str:byte(nextPos)
        if b == 93 then -- ']'
            return arr, nextPos + 1, nil
        elseif b == 44 then -- ','
            nextPos, err = SkipWhitespaceAndComments(str, nextPos + 1)
            if err then return nil, nil, err end
            -- Allow trailing comma before ']'
            if str:byte(nextPos) == 93 then
                return arr, nextPos + 1, nil
            end
        else
            return nil, nil, FormatError(str, nextPos, "expected ',' or ']' in array")
        end
    end
end

local function ParseObject(str, pos, depth)
    if depth > 64 then
        return nil, nil, FormatError(str, pos, "maximum nesting depth exceeded")
    end
    local obj = {}
    local nextPos, err = SkipWhitespaceAndComments(str, pos + 1)
    if err then return nil, nil, err end

    if str:byte(nextPos) == 125 then -- '}'
        return obj, nextPos + 1, nil
    end

    while true do
        if str:byte(nextPos) ~= 34 then -- '"'
            return nil, nil, FormatError(str, nextPos, "expected quoted property name in object")
        end
        local key, afterKey, kErr = ParseString(str, nextPos)
        if kErr then return nil, nil, kErr end

        nextPos, err = SkipWhitespaceAndComments(str, afterKey)
        if err then return nil, nil, err end

        if str:byte(nextPos) ~= 58 then -- ':'
            return nil, nil, FormatError(str, nextPos, "expected ':' after property name '" .. tostring(key) .. "'")
        end

        nextPos, err = SkipWhitespaceAndComments(str, nextPos + 1)
        if err then return nil, nil, err end

        local val, afterVal, vErr = ParseValue(str, nextPos, depth + 1)
        if vErr then return nil, nil, vErr end
        obj[key] = val

        nextPos, err = SkipWhitespaceAndComments(str, afterVal)
        if err then return nil, nil, err end

        local b = str:byte(nextPos)
        if b == 125 then -- '}'
            return obj, nextPos + 1, nil
        elseif b == 44 then -- ','
            nextPos, err = SkipWhitespaceAndComments(str, nextPos + 1)
            if err then return nil, nil, err end
            -- Allow trailing comma before '}'
            if str:byte(nextPos) == 125 then
                return obj, nextPos + 1, nil
            end
        else
            return nil, nil, FormatError(str, nextPos, "expected ',' or '}' in object")
        end
    end
end

ParseValue = function(str, pos, depth)
    local nextPos, err = SkipWhitespaceAndComments(str, pos)
    if err then return nil, nil, err end

    local b = str:byte(nextPos)
    if not b then
        return nil, nil, FormatError(str, nextPos, "unexpected end of input")
    end

    if b == 123 then -- '{'
        return ParseObject(str, nextPos, depth)
    elseif b == 91 then -- '['
        return ParseArray(str, nextPos, depth)
    elseif b == 34 then -- '"'
        return ParseString(str, nextPos)
    elseif b == 45 or (b >= 48 and b <= 57) then -- '-' or '0'..'9'
        return ParseNumber(str, nextPos)
    elseif str:sub(nextPos, nextPos + 3) == "true" then
        return true, nextPos + 4, nil
    elseif str:sub(nextPos, nextPos + 4) == "false" then
        return false, nextPos + 5, nil
    elseif str:sub(nextPos, nextPos + 3) == "null" then
        return nil, nextPos + 4, nil
    else
        local ch = str:sub(nextPos, nextPos)
        return nil, nil, FormatError(str, nextPos, "unexpected character '" .. ch .. "'")
    end
end

-- Decode a JSON or JSONC string. Returns (value, nil) on success, or (nil, errMsg) on failure.
function Json.Decode(rawStr)
    if type(rawStr) ~= "string" then
        return nil, "expected string input"
    end
    local str = rawStr
    -- Strip UTF-8 BOM if present
    if str:sub(1, 3) == "\239\187\191" then
        str = str:sub(4)
    end

    local pos, err = SkipWhitespaceAndComments(str, 1)
    if err then return nil, err end
    if pos > #str then
        return nil, "empty JSON input"
    end

    local val, afterPos, parseErr = ParseValue(str, pos, 0)
    if parseErr then
        return nil, parseErr
    end

    local tailPos, tailErr = SkipWhitespaceAndComments(str, afterPos)
    if tailErr then return nil, tailErr end
    if tailPos <= #str then
        return nil, FormatError(str, tailPos, "unexpected trailing token '" .. str:sub(tailPos, tailPos) .. "'")
    end

    return val, nil
end

-- Quick check whether a raw file string looks like JSON/JSONC (starts with '{' or a JSON array '['
-- after BOM/whitespace/comments, while rejecting INI section headers like '[FlamesOfZamorak]').
function Json.LooksLikeJson(rawStr)
    if type(rawStr) ~= "string" then return false end
    local str = rawStr
    if str:sub(1, 3) == "\239\187\191" then
        str = str:sub(4)
    end
    local pos, err = SkipWhitespaceAndComments(str, 1)
    if err or not pos or pos > #str then return false end
    local b = str:byte(pos)
    if b == 123 then -- '{'
        return true
    end
    if b == 91 then -- '['
        local nextPos, nextErr = SkipWhitespaceAndComments(str, pos + 1)
        if nextErr or not nextPos or nextPos > #str then return false end
        local nb = str:byte(nextPos)
        if nb == 93 or nb == 123 or nb == 91 or nb == 34 or nb == 45 or (nb >= 48 and nb <= 57) then
            return true
        end
        if str:sub(nextPos, nextPos + 3) == "true" or str:sub(nextPos, nextPos + 3) == "null" then
            local ch = str:sub(nextPos + 4, nextPos + 4)
            return ch == "" or ch:match("[%s,%]]") ~= nil
        end
        if str:sub(nextPos, nextPos + 4) == "false" then
            local ch = str:sub(nextPos + 5, nextPos + 5)
            return ch == "" or ch:match("[%s,%]]") ~= nil
        end
        return false
    end
    return false
end

local function EscapeString(s)
    local out = s:gsub('[%z\1-\31\\"]', function(c)
        if c == '"' then return '\\"'
        elseif c == '\\' then return '\\\\'
        elseif c == '\b' then return '\\b'
        elseif c == '\f' then return '\\f'
        elseif c == '\n' then return '\\n'
        elseif c == '\r' then return '\\r'
        elseif c == '\t' then return '\\t'
        else return string.format("\\u%04x", c:byte())
        end
    end)
    return '"' .. out .. '"'
end

local EMPTY_ARRAY_MT = { __arcane_json_array = true }

-- Create an explicit empty JSON array ([]) so Json.Encode does not emit {} for empty lists.
function Json.EmptyArray()
    return setmetatable({}, EMPTY_ARRAY_MT)
end

-- Mark an existing table as a JSON array (preserves [] when empty).
function Json.AsArray(tbl)
    tbl = tbl or {}
    return setmetatable(tbl, EMPTY_ARRAY_MT)
end

local function IsArrayTable(tbl)
    local mt = getmetatable(tbl)
    local maxIdx = 0
    local count = 0
    for k, _ in pairs(tbl) do
        if type(k) ~= "number" or k <= 0 or math.floor(k) ~= k then
            return false, 0
        end
        if k > maxIdx then maxIdx = k end
        count = count + 1
    end
    if count == 0 then
        if mt == EMPTY_ARRAY_MT then
            return true, 0
        end
        return false, 0
    end
    if maxIdx ~= count then return false, 0 end
    return true, count
end

local function EncodeValue(val, indent, level, seen)
    local t = type(val)
    if val == nil then
        return "null"
    elseif t == "boolean" then
        return val and "true" or "false"
    elseif t == "number" then
        if val ~= val or val == math.huge or val == -math.huge then
            return "null"
        end
        if math.floor(val) == val and math.abs(val) < 1e15 then
            return string.format("%d", val)
        end
        return tostring(val)
    elseif t == "string" then
        return EscapeString(val)
    elseif t == "table" then
        if seen[val] then
            error("circular reference in table")
        end
        seen[val] = true
        local isArr, arrLen = IsArrayTable(val)
        local pad = indent and string.rep(" ", indent * (level + 1)) or ""
        local closePad = indent and string.rep(" ", indent * level) or ""
        local sep = indent and (",\n" .. pad) or ","
        local out
        if isArr then
            if arrLen == 0 then
                out = "[]"
            else
                local items = {}
                for i = 1, arrLen do
                    items[i] = EncodeValue(val[i], indent, level + 1, seen)
                end
                if indent then
                    out = "[\n" .. pad .. table.concat(items, sep) .. "\n" .. closePad .. "]"
                else
                    out = "[" .. table.concat(items, ",") .. "]"
                end
            end
        else
            local keys = {}
            for k, _ in pairs(val) do
                if type(k) == "string" then
                    keys[#keys + 1] = k
                end
            end
            table.sort(keys)
            if #keys == 0 then
                out = "{}"
            else
                local items = {}
                local colon = indent and ": " or ":"
                for i, k in ipairs(keys) do
                    items[i] = EscapeString(k) .. colon .. EncodeValue(val[k], indent, level + 1, seen)
                end
                if indent then
                    out = "{\n" .. pad .. table.concat(items, sep) .. "\n" .. closePad .. "}"
                else
                    out = "{" .. table.concat(items, ",") .. "}"
                end
            end
        end
        seen[val] = nil
        return out
    else
        return "null"
    end
end

-- Encode a Lua value to JSON string. Optional opts = { indent = 2 } for pretty printing.
function Json.Encode(val, opts)
    local indent = opts and opts.indent or nil
    local ok, res = pcall(EncodeValue, val, indent, 0, {})
    if not ok then
        return nil, tostring(res)
    end
    return res, nil
end

return Json
