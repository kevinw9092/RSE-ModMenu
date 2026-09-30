-- RSE-ModMenu - RuneScape: Dragonwilds
-- Based on Mod Menu by Maxxfilth (MIT). The mod id stays "ModMenu" and every shared variable name is
-- unchanged, so mods written for Mod Menu keep working.
--
-- One MODS entry in the pause menu (Esc). Every installed mod that ships a modmenu.json file gets a
-- page of settings there, drawn with the game's own checkboxes, sliders and buttons.
--
-- For mod authors: see README.md in this folder. In short, put a modmenu.json next to your
-- enabled.txt listing your options. Mod Menu saves the player's choices into your config file, and
-- also publishes them as UE4SS shared variables for live updates:
--   ModMenu.version          "1.0.0" while Mod Menu is loaded
--   ModMenu.<id>.<key>       current value (bool, number or string)
--   ModMenu.<id>.rev         number, +1 on every change for that mod
--   ModMenu.<id>.action      "<action>#<n>" when one of your buttons is clicked
-- Your mod keeps working without Mod Menu installed: it just reads its config file as before.
--
-- Verified 2026-09-16 (ModMenuProbe): shared variables cross mods (string/number/bool), the Mods
-- folder can be listed with IterateGameDirectories, and the game's settings widgets can be created.

local TAG = "[ModMenu] "
local VERSION = "1.1.1"
local SCHEMA = 1
local function log(msg) print(TAG .. tostring(msg) .. "\n") end

local cfg = {
    ShowInPauseMenu = true,  -- adds MODS to the pause menu (Esc)
    MenuKey = "none",        -- optional key that opens the menu anywhere, including the main menu, e.g. HOME
    PanelScale = 100,        -- size of the whole panel, percent. 100 = the size it has always been
}

local function modRoot()
    local src = (debug.getinfo(1, "S").source or ""):gsub("^@", "")
    local dir = src:match("^(.*)[/\\][^/\\]*$")
    if not dir then return nil end
    return (dir:match("^(.*)[/\\][^/\\]*$"))
end

local function valid(o)
    if not o then return false end
    local ok, v = pcall(function() return o:IsValid() end)
    return ok and v
end

local function get(fn)
    local ok, v = pcall(fn)
    if ok then return v end
    return nil
end

-- JSON --------------------------------------------------------------------------------------------
-- Small strict decoder: objects, arrays, strings (with \uXXXX), numbers, true/false/null.
local json = {}
do
    local function skip(s, i)
        while true do
            local c = s:sub(i, i)
            if c == " " or c == "\t" or c == "\r" or c == "\n" then i = i + 1
            elseif c == "/" and s:sub(i + 1, i + 1) == "/" then   -- tolerate // comments
                local e = s:find("\n", i, true); i = e and e + 1 or #s + 1
            else return i end
        end
    end
    local function utf8char(cp)
        if cp < 0x80 then return string.char(cp)
        elseif cp < 0x800 then return string.char(0xC0 + math.floor(cp / 0x40), 0x80 + cp % 0x40)
        elseif cp < 0x10000 then return string.char(0xE0 + math.floor(cp / 0x1000), 0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
        else return string.char(0xF0 + math.floor(cp / 0x40000), 0x80 + math.floor(cp / 0x1000) % 0x40,
                                0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40) end
    end
    local value
    local function err(s, i, what) error(string.format("%s at character %d", what, i), 0) end
    local function str(s, i)
        local out, j = {}, i + 1
        while true do
            local c = s:sub(j, j)
            if c == "" then err(s, j, "unterminated string") end
            if c == '"' then return table.concat(out), j + 1 end
            if c == "\\" then
                local n = s:sub(j + 1, j + 1)
                local map = { ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }
                if map[n] then out[#out + 1] = map[n]; j = j + 2
                elseif n == "u" then
                    local hex = s:sub(j + 2, j + 5)
                    if not hex:match("^%x%x%x%x$") then err(s, j, "bad \\u escape") end
                    local cp = tonumber(hex, 16); j = j + 6
                    -- A surrogate pair (😀) is one character above U+FFFF, e.g. an emoji.
                    local low = s:match("^\\u([dD][c-fC-F]%x%x)", j)
                    if cp >= 0xD800 and cp <= 0xDBFF and low then
                        cp = 0x10000 + (cp - 0xD800) * 0x400 + (tonumber(low, 16) - 0xDC00); j = j + 6
                    end
                    out[#out + 1] = utf8char(cp)
                else err(s, j, "bad escape") end
            else out[#out + 1] = c; j = j + 1 end
        end
    end
    value = function(s, i)
        i = skip(s, i)
        local c = s:sub(i, i)
        if c == "{" then
            local obj = {}
            i = skip(s, i + 1)
            if s:sub(i, i) == "}" then return obj, i + 1 end
            while true do
                i = skip(s, i)
                if s:sub(i, i) ~= '"' then err(s, i, "expected a quoted key") end
                local k; k, i = str(s, i)
                i = skip(s, i)
                if s:sub(i, i) ~= ":" then err(s, i, "expected ':'") end
                obj[k], i = value(s, i + 1)
                i = skip(s, i)
                local d = s:sub(i, i)
                if d == "}" then return obj, i + 1 end
                if d ~= "," then err(s, i, "expected ',' or '}'") end
                i = skip(s, i + 1)
                if s:sub(i, i) == "}" then return obj, i + 1 end   -- tolerate a trailing comma
            end
        elseif c == "[" then
            local arr = {}
            i = skip(s, i + 1)
            if s:sub(i, i) == "]" then return arr, i + 1 end
            while true do
                arr[#arr + 1], i = value(s, i)
                i = skip(s, i)
                local d = s:sub(i, i)
                if d == "]" then return arr, i + 1 end
                if d ~= "," then err(s, i, "expected ',' or ']'") end
                i = skip(s, i + 1)
                if s:sub(i, i) == "]" then return arr, i + 1 end   -- tolerate a trailing comma
            end
        elseif c == '"' then return str(s, i)
        elseif s:sub(i, i + 3) == "true" then return true, i + 4
        elseif s:sub(i, i + 4) == "false" then return false, i + 5
        elseif s:sub(i, i + 3) == "null" then return nil, i + 4
        else
            local num = s:match("^-?%d+%.?%d*[eE]?[-+]?%d*", i)
            if num and num ~= "" and tonumber(num) then return tonumber(num), i + #num end
            err(s, i, "unexpected '" .. c .. "'")
        end
    end
    function json.decode(s)
        s = s:gsub("^\239\187\191", "")                       -- UTF-8 BOM
        local ok, v, i = pcall(value, s, 1)
        if not ok then return nil, v end
        i = skip(s, i)
        if i <= #s then return nil, "extra text after the end at character " .. i end
        return v
    end
    local function esc(str)
        return '"' .. str:gsub('[%c"\\]', function(ch)
            local m = { ['"'] = '\\"', ["\\"] = "\\\\", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }
            return m[ch] or string.format("\\u%04x", ch:byte())
        end) .. '"'
    end
    -- Nested objects and arrays are written back too: the flat-only writer dropped them, so saving one
    -- setting erased every nested value in a mod's JSON config.
    local function isArray(t)
        local n = #t
        if n == 0 then return false end
        for k in pairs(t) do
            if type(k) ~= "number" or k < 1 or k > n or k % 1 ~= 0 then return false end
        end
        return true
    end
    local function encodeValue(v, indent)
        local tv = type(v)
        if tv == "boolean" or tv == "number" then return tostring(v) end
        if tv ~= "table" then return esc(tostring(v)) end
        local inner = indent .. "  "
        local parts = {}
        if isArray(v) then
            for i = 1, #v do parts[i] = inner .. encodeValue(v[i], inner) end
            return "[\n" .. table.concat(parts, ",\n") .. "\n" .. indent .. "]"
        end
        local keys = {}
        for k in pairs(v) do keys[#keys + 1] = tostring(k) end
        if #keys == 0 then return "{}" end
        table.sort(keys)
        for _, k in ipairs(keys) do parts[#parts + 1] = inner .. esc(k) .. ": " .. encodeValue(v[k], inner) end
        return "{\n" .. table.concat(parts, ",\n") .. "\n" .. indent .. "}"
    end
    function json.encodeFlat(obj, order)
        local lines = {}
        for _, k in ipairs(order) do
            lines[#lines + 1] = "  " .. esc(k) .. ": " .. encodeValue(obj[k], "  ")
        end
        return "{\n" .. table.concat(lines, ",\n") .. "\n}\n"
    end
end

-- Files -------------------------------------------------------------------------------------------
local MAX_FILE = 256 * 1024
local function readFile(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local s = f:read(MAX_FILE + 1)
    f:close()
    if s and #s > MAX_FILE then return nil, "file is larger than 256 KB" end
    return s or ""
end

-- Writes through a temporary file, so a crash or a full disk mid-write never leaves a mod's config half
-- written: the old file stays until the new one is complete. Windows' rename does not replace an existing
-- file, so the old one is moved aside first and put back if the swap fails.
local function writeFile(path, text)
    local tmp, old = path .. ".modmenu-tmp", path .. ".modmenu-old"
    local f = io.open(tmp, "wb")
    if not f then return false end
    local okW = f:write(text) ~= nil
    local okC = f:close()                              -- a full disk can fail only here, when the buffer is flushed
    if not (okW and okC) then os.remove(tmp); return false end
    os.remove(old)
    local hadOld = os.rename(path, old)
    if os.rename(tmp, path) then
        if hadOld then os.remove(old) end
        return true
    end
    if hadOld then os.rename(old, path) end
    -- Renaming not allowed here (read-only folder, antivirus lock): write in place as before.
    os.remove(tmp)
    local g = io.open(path, "wb")
    if not g then return false end
    local okG = g:write(text) ~= nil
    local okGC = g:close()
    return (okG and okGC) and true or false
end

-- A crash between writeFile's two renames leaves a mod's config moved aside with nothing at its own name.
-- Put it back before the file is read, or the mod would start from defaults and the next save would bury it.
local function restoreMovedAside(path)
    local f = io.open(path, "rb")
    if f then f:close(); return end
    local old = path .. ".modmenu-old"
    local g = io.open(old, "rb")
    if not g then return end
    g:close()
    if os.rename(old, path) then log("restored " .. path .. " from an interrupted save") end
end

-- Schemas -----------------------------------------------------------------------------------------
-- The schema file has two accepted names. CurseForge's "RSDragonwilds UE4SS Mods" category only
-- accepts .txt/.lua/.dll/.pak/.utoc/.ucas and rejects the whole archive over a .json, so builds for
-- that site ship the identical file as modmenu.txt. The contents are JSON either way; only the name
-- differs. .json is tried first so an existing install keeps loading exactly the file it always did.
local SCHEMA_FILES = { "modmenu.json", "modmenu.txt" }

local TYPES = { header = true, toggle = true, slider = true, number = true, choice = true, key = true, text = true, button = true }
local mods = {}          -- sorted list of mod entries
local modsById = {}

local function round(v, decimals)
    local m = 10 ^ (decimals or 0)
    return math.floor(v * m + 0.5) / m
end

local function decimalsFor(s)
    if s.decimals then return math.max(0, math.min(4, math.floor(s.decimals))) end
    local step = s.step or 1
    if step >= 1 then return 0 end
    local d = 0
    while d < 4 and math.abs(step * 10 ^ d - math.floor(step * 10 ^ d + 0.5)) > 1e-9 do d = d + 1 end
    return d
end

-- Validates one setting. Returns a cleaned copy or nil plus a reason.
local function checkSetting(raw, idx, seen, restartDefault)
    if type(raw) ~= "table" then return nil, "setting " .. idx .. " is not an object" end
    local t = raw.type
    if type(t) ~= "string" or not TYPES[t] then return nil, "setting " .. idx .. ": unknown type '" .. tostring(t) .. "'" end
    if t == "number" then t = "slider" end
    local s = { type = t, label = type(raw.label) == "string" and raw.label:sub(1, 80) or nil,
                tooltip = type(raw.tooltip) == "string" and raw.tooltip:sub(1, 300) or nil }
    if t == "header" then
        s.label = s.label or ""
        return s
    end
    if t == "button" then
        if type(raw.action) ~= "string" or raw.action == "" then return nil, "button " .. idx .. " needs an \"action\"" end
        s.action = raw.action:sub(1, 60)
        s.label = s.label or s.action
        return s
    end
    if type(raw.key) ~= "string" or not raw.key:match("^[%w_%.%-]+$") then
        return nil, "setting " .. idx .. " needs a \"key\" made of letters, digits, _ . -"
    end
    if seen[raw.key] then return nil, "setting " .. idx .. ": key '" .. raw.key .. "' is used twice" end
    s.key = raw.key
    s.label = s.label or raw.key
    if raw.restart == nil then s.restart = restartDefault == true else s.restart = raw.restart == true end
    if t == "toggle" then
        s.default = raw.default == true
    elseif t == "slider" then
        local mn, mx = tonumber(raw.min), tonumber(raw.max)
        if not mn or not mx or mn >= mx then return nil, "slider '" .. s.key .. "' needs min < max" end
        s.min, s.max = mn, mx
        s.step = tonumber(raw.step)
        if not s.step or s.step <= 0 then s.step = (mx - mn) / 100 end
        s.decimals = decimalsFor({ decimals = tonumber(raw.decimals), step = s.step })
        s.suffix = type(raw.suffix) == "string" and raw.suffix:sub(1, 8) or ""
        local d = tonumber(raw.default) or mn
        s.default = math.max(mn, math.min(mx, d))
    elseif t == "choice" then
        if type(raw.options) ~= "table" or #raw.options < 1 then return nil, "choice '" .. s.key .. "' needs an \"options\" list" end
        s.options = {}
        for _, o in ipairs(raw.options) do
            if type(o) == "string" or type(o) == "number" then s.options[#s.options + 1] = tostring(o):sub(1, 40) end
            if #s.options >= 50 then break end
        end
        if #s.options == 0 then return nil, "choice '" .. s.key .. "' has no usable options" end
        s.default = tostring(raw.default or s.options[1])
        local found = false
        for _, o in ipairs(s.options) do if o == s.default then found = true end end
        if not found then s.default = s.options[1] end
    elseif t == "key" then
        s.default = type(raw.default) == "string" and raw.default or "none"
    elseif t == "text" then
        s.maxLength = math.max(1, math.min(200, tonumber(raw.maxLength) or 60))
        s.default = type(raw.default) == "string" and raw.default:sub(1, s.maxLength) or ""
    end
    seen[s.key] = true
    return s
end

-- Converts a stored string (or JSON value) into the setting's type. nil = unusable.
local function coerce(s, v)
    if v == nil then return nil end
    if s.type == "toggle" then
        if type(v) == "boolean" then return v end
        local l = tostring(v):lower()
        if l == "true" or l == "1" or l == "yes" or l == "on" then return true end
        if l == "false" or l == "0" or l == "no" or l == "off" then return false end
        return nil
    elseif s.type == "slider" then
        local n = tonumber(v)
        if not n then return nil end
        return round(math.max(s.min, math.min(s.max, n)), s.decimals)
    elseif s.type == "choice" then
        v = tostring(v)
        for _, o in ipairs(s.options) do if o:lower() == v:lower() then return o end end
        return nil
    elseif s.type == "key" or s.type == "text" then
        v = tostring(v):gsub("[\r\n]", " ")
        if s.maxLength then v = v:sub(1, s.maxLength) end
        return v
    end
    return nil
end

local function formatValue(s, v)
    if s.type == "toggle" then return v and "true" or "false" end
    if s.type == "slider" then
        if s.decimals == 0 then return tostring(math.floor(v + 0.5)) end
        local str = string.format("%." .. s.decimals .. "f", v)
        return (str:gsub("0+$", ""):gsub("%.$", ""))
    end
    return tostring(v)
end

-- Config files ------------------------------------------------------------------------------------
local function stripComment(v)
    -- "value   # note" -> "value". A # or ; only starts a comment after whitespace.
    local cut = v:find("%s[#;]")
    if cut then return (v:sub(1, cut - 1):gsub("%s+$", "")), v:sub(cut) end
    return (v:gsub("%s+$", "")), ""
end

-- Lua files: settings written as plain assignments near the top of the script, e.g.
--     local MaxStack = 999          -- comment kept
--     ShowIcons = true,             (a field inside a settings table)
-- Only the first assignment to each name, with a literal number, true/false or quoted string, is used.
local function luaLiteral(v)
    local q = v:sub(1, 1)
    if q == '"' or q == "'" then
        local i = 2
        while i <= #v do
            local ch = v:sub(i, i)
            if ch == "\\" then i = i + 2
            elseif ch == q then
                local body = v:sub(2, i - 1):gsub("\\(.)", "%1")
                return body, v:sub(i + 1), q
            else i = i + 1 end
        end
        return nil
    end
    local b = v:match("^true") or v:match("^false")
    if b then return b == "true", v:sub(#b + 1) end
    local n = v:match("^%-?%d+%.?%d*")
    if n and tonumber(n) then return tonumber(n), v:sub(#n + 1) end
    return nil
end

local function luaLine(line)
    local indent, loc, name, eq, rest = line:match("^(%s*)(local%s+)([%a_][%w_]*)(%s*=%s*)(.-)%s*$")
    if not indent then
        indent, name, eq, rest = line:match("^(%s*)([%a_][%w_]*)(%s*=%s*)(.-)%s*$")
        loc = ""
    end
    if not indent or #indent > 8 then return nil end
    local val, tail, q = luaLiteral(rest)
    if val == nil then return nil end
    if not (tail:match("^%s*,?%s*$") or tail:match("^%s*,?%s*%-%-")) then return nil end
    return { pre = indent .. loc .. name .. eq, name = name, value = val, tail = tail, quote = q }
end

local function readConfig(m)
    local text = readFile(m.cfgPath)
    local found = {}
    if not text then return found end
    if m.format == "json" then
        local obj = json.decode(text)
        if type(obj) == "table" then found = obj
        else m.errors[#m.errors + 1] = "config file is not valid JSON; defaults shown" end
        return found
    end
    if m.format == "lua" then
        for line in (text .. "\n"):gmatch("([^\n]*)\n") do
            local l = luaLine((line:gsub("\r$", "")))
            if l and found[l.name] == nil then found[l.name] = l.value end
        end
        for _, st in ipairs(m.settings) do
            if st.key and found[st.key] == nil then
                m.errors[#m.errors + 1] = "'" .. st.key .. "' is not a plain value in " .. (m.cfgPath:match("[^\\]+$") or "the Lua file") .. ", so it cannot be changed here"
                st.locked = true
            end
        end
        return found
    end
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
        line = line:gsub("\r$", "")
        local k, v = line:match("^%s*([%w_%.%-]+)%s*=%s*(.-)%s*$")
        if k then found[k] = (stripComment(v)) end
    end
    return found
end

local function loadValues(m)
    local found = readConfig(m)
    m.values = {}
    for _, s in ipairs(m.settings) do
        if s.key then
            local v = coerce(s, found[s.key])
            if v == nil then v = s.default end
            m.values[s.key] = v
        end
    end
end

local function saveValues(m)
    if m.format == "json" then
        local text = readFile(m.cfgPath)
        local obj = (text and json.decode(text)) or {}
        if type(obj) ~= "table" then obj = {} end
        local order, seenK = {}, {}
        for _, s in ipairs(m.settings) do
            if s.key then obj[s.key] = m.values[s.key]; order[#order + 1] = s.key; seenK[s.key] = true end
        end
        local rest = {}
        for k in pairs(obj) do if not seenK[k] then rest[#rest + 1] = k end end
        table.sort(rest, function(a, b) return tostring(a) < tostring(b) end)
        for _, k in ipairs(rest) do order[#order + 1] = k end
        return writeFile(m.cfgPath, json.encodeFlat(obj, order))
    end
    local text = readFile(m.cfgPath) or ""
    local nl = text:find("\r\n", 1, true) and "\r\n" or "\n"
    if m.format == "lua" then
        if text == "" then return false end
        local out, doneL, byKeyL = {}, {}, {}
        for _, st in ipairs(m.settings) do if st.key and not st.locked then byKeyL[st.key] = st end end
        for line in (text .. "\n"):gmatch("([^\n]*)\n") do
            line = line:gsub("\r$", "")
            local l = luaLine(line)
            local st = l and byKeyL[l.name]
            if st and not doneL[l.name] then
                local v = m.values[l.name]
                local lit
                if type(v) == "boolean" then lit = tostring(v)
                elseif type(v) == "number" then lit = formatValue(st, v)
                else
                    local q = l.quote or '"'
                    lit = q .. (tostring(v):gsub("\\", "\\\\"):gsub(q, "\\" .. q)) .. q
                end
                line = l.pre .. lit .. l.tail
                doneL[l.name] = true
            end
            out[#out + 1] = line
        end
        while #out > 0 and out[#out] == "" do out[#out] = nil end
        return writeFile(m.cfgPath, table.concat(out, nl) .. nl)
    end
    local lines, done = {}, {}
    local byKey = {}
    for _, s in ipairs(m.settings) do if s.key then byKey[s.key] = s end end
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
        line = line:gsub("\r$", "")
        local indent, k, v = line:match("^(%s*)([%w_%.%-]+)%s*=%s*(.-)%s*$")
        local s = k and byKey[k]
        if s and not done[k] then
            local _, comment = stripComment(v)
            line = indent .. k .. " = " .. formatValue(s, m.values[k]) .. (comment ~= "" and ("   " .. comment:gsub("^%s+", "")) or "")
            done[k] = true
        end
        lines[#lines + 1] = line
    end
    while #lines > 0 and lines[#lines] == "" do lines[#lines] = nil end
    -- Settings missing from the file are only added when they differ from the default, so files stay tidy.
    local header = text:find("# Set in Mod Menu", 1, true) ~= nil
    for _, s in ipairs(m.settings) do
        if s.key and not done[s.key] and m.values[s.key] ~= s.default then
            if not header then lines[#lines + 1] = ""; lines[#lines + 1] = "# Set in Mod Menu"; header = true end
            lines[#lines + 1] = s.key .. " = " .. formatValue(s, m.values[s.key])
        end
    end
    return writeFile(m.cfgPath, table.concat(lines, nl) .. nl)
end

-- Shared variables --------------------------------------------------------------------------------
local function share(name, v)
    local ok, e = pcall(function() ModRef:SetSharedVariable(name, v) end)
    if not ok then log("could not publish " .. name .. ": " .. tostring(e)) end
end

local function publishAll(m)
    for _, s in ipairs(m.settings) do
        if s.key then share("ModMenu." .. m.id .. "." .. s.key, m.values[s.key]) end
    end
    share("ModMenu." .. m.id .. ".rev", m.rev)
end

-- Discovery ---------------------------------------------------------------------------------------
local function loadSchema(folderName, dirPath)
    local m = { folder = folderName, dir = dirPath, errors = {}, settings = {}, values = {}, rev = 0, actionN = 0 }
    local text, ferr = nil, nil
    for _, fname in ipairs(SCHEMA_FILES) do
        local t, e = readFile(dirPath .. "\\" .. fname)
        if t then text = t; break end
        ferr = ferr or e                                   -- keep "larger than 256 KB" from the first file
    end
    if not text then m.errors[#m.errors + 1] = ferr or "modmenu.json could not be read"; text = nil end
    local doc, jerr = nil, nil
    if text then doc, jerr = json.decode(text) end
    if text and type(doc) ~= "table" then
        m.errors[#m.errors + 1] = "modmenu.json is not valid JSON: " .. tostring(jerr)
        doc = {}
    end
    doc = doc or {}
    m.id = (type(doc.id) == "string" and doc.id:match("^[%w_%-]+$")) and doc.id or folderName
    m.name = type(doc.name) == "string" and doc.name:sub(1, 40) or folderName
    m.author = type(doc.author) == "string" and doc.author:sub(1, 40) or nil
    m.version = (type(doc.version) == "string" or type(doc.version) == "number") and tostring(doc.version):sub(1, 20) or nil
    m.description = type(doc.description) == "string" and doc.description:sub(1, 300) or nil
    local schema = tonumber(doc.schema) or 1
    if schema > SCHEMA then
        m.errors[#m.errors + 1] = "this mod needs a newer Mod Menu (file format " .. schema .. ")"
        return m
    end
    local c = type(doc.config) == "table" and doc.config or {}
    local file = type(c.file) == "string" and c.file or "config.txt"
    if file:find("%.%.") or file:find("^[/\\]") or file:find(":") then
        m.errors[#m.errors + 1] = "config file must be inside the mod folder"
        file = "config.txt"
    end
    m.format = (c.format == "json" or c.format == "lua") and c.format or "keyvalue"
    if m.format == "lua" and type(c.file) ~= "string" then file = "Scripts/main.lua" end
    m.cfgPath = dirPath .. "\\" .. file:gsub("/", "\\")
    local seen = {}
    if type(doc.settings) == "table" then
        for i, raw in ipairs(doc.settings) do
            if i > 200 then m.errors[#m.errors + 1] = "only the first 200 settings are shown"; break end
            local s, why = checkSetting(raw, i, seen, m.format == "lua")
            if s then m.settings[#m.settings + 1] = s else m.errors[#m.errors + 1] = why end
        end
    elseif text then
        m.errors[#m.errors + 1] = "modmenu.json has no \"settings\" list"
    end
    restoreMovedAside(m.cfgPath)
    loadValues(m)
    return m
end

-- The Mods folder, whatever platform folder the game runs from. Steam is Binaries\Win64, Game Pass is
-- Binaries\WinGDK (reported by JourneyOver 2026-09-17: on Game Pass this returned nothing, so Mod Menu
-- listed 0 configurable mods on every launch).
local PLATFORM_DIRS = { "Win64", "WinGDK", "Win32", "WinArm64" }

local function modsDirTable()
    local ok, dirs = pcall(IterateGameDirectories)
    if not ok or type(dirs) ~= "table" then return nil end
    local bin = nil
    pcall(function() bin = dirs.Game.Binaries end)
    if type(bin) ~= "table" then return nil end
    -- 1.0.11: the platform folder this script runs from goes first. A Game Pass install with a stray
    -- Binaries\Win64\ue4ss (left from a Steam guide) used to list THAT folder, find 0 mods and never
    -- look in WinGDK (548 ssamanda8, 26 Sep; renaming the stray folder fixed it).
    local src = (debug.getinfo(1, "S").source or ""):gsub("^@", "")
    local own = src:match("[/\\][Bb]inaries[/\\]([^/\\]+)[/\\]")
    local order = { own }
    for _, plat in ipairs(PLATFORM_DIRS) do
        if plat ~= own then order[#order + 1] = plat end
    end
    for _, plat in ipairs(order) do
        local t = nil
        pcall(function() t = bin[plat].ue4ss.Mods end)
        if not t then pcall(function() t = bin[plat].Mods end) end
        if type(t) == "table" then return t end
    end
    -- any other platform folder that has a ue4ss/Mods inside it
    local found = nil
    pcall(function()
        for name, node in pairs(bin) do
            if not found and type(node) == "table" and not tostring(name):find("^__") then
                local t = nil
                pcall(function() t = node.ue4ss.Mods end)
                if not t then pcall(function() t = node.Mods end) end
                if type(t) == "table" then found = t end
            end
        end
    end)
    return found
end

-- Fallback when the directory listing gives nothing (seen on Game Pass, JourneyOver 2026-09-17: Mod Menu
-- found 0 configurable mods on every launch there). This script's own path tells us where the Mods folder
-- is, and a plain directory listing names the folders in it; each one is then probed for a modmenu.json by
-- opening the file. UE4SS's mods.txt is no use here: it only lists the built-in mods, not ones with enabled.txt.
--
-- Measured in game 2026-09-17: the io.popen call costs 5.5 s the first time (cmd.exe warm-up) and 500 ms
-- when warm, while the modmenu.json probes are free. discover() also runs from openPanel() ON THE GAME
-- THREAD, so this result is cached for the session: nobody installs a mod without restarting the game, and
-- half a second of freeze on every menu open would be worse than the bug this fixes.
local dirListCache = nil   -- nil = not tried, false = tried and found nothing, table = the result

local function modsFromDirListing()
    if dirListCache == false then return nil end
    if dirListCache then return dirListCache.list, dirListCache.root end
    local src = (debug.getinfo(1, "S").source or ""):gsub("^@", "")
    local scripts = src:match("^(.*)[/\\][^/\\]*$")
    local myFolder = scripts and scripts:match("^(.*)[/\\][^/\\]*$")
    local modsRoot = myFolder and myFolder:match("^(.*)[/\\][^/\\]*$")
    if not modsRoot then dirListCache = false; return nil end
    local ok, pipe = pcall(io.popen, 'dir /b /ad "' .. modsRoot .. '"')
    if not ok or not pipe then dirListCache = false; return nil end
    local out = {}
    local okRead = pcall(function()
        for line in pipe:lines() do
            local name = tostring(line):gsub("%s+$", "")
            if name ~= "" and #out < 100 then
                local found = false
                for _, fname in ipairs(SCHEMA_FILES) do
                    local probe = io.open(modsRoot .. "\\" .. name .. "\\" .. fname, "r")
                    if probe then probe:close(); found = true; break end
                end
                if found then
                    out[#out + 1] = { folder = name, path = modsRoot .. "\\" .. name }
                end
            end
        end
    end)
    pcall(function() pipe:close() end)
    if not okRead or #out == 0 then dirListCache = false; return nil end
    dirListCache = { list = out, root = modsRoot }
    return out, modsRoot
end

local function addMod(list, byId, folder, path)
    local okL, m = pcall(loadSchema, tostring(folder), tostring(path))
    if okL and m then
        local prev = modsById[m.id]
        if prev and prev.folder == m.folder then m.rev = prev.rev; m.actionN = prev.actionN end
        if byId[m.id] then
            m.errors[#m.errors + 1] = "id '" .. m.id .. "' is also used by " .. byId[m.id].folder
            m.id = m.id .. "_" .. m.folder
        end
        byId[m.id] = m
        list[#list + 1] = m
    else
        log("could not load " .. tostring(folder) .. ": " .. tostring(m))
    end
end

local warnedNoList, saidDirect = false, false

local function discover()
    local dirT = modsDirTable()
    local list, byId = {}, {}
    if not dirT then
        -- Game Pass and any other layout IterateGameDirectories cannot walk: list the folder ourselves.
        local fallback, root = modsFromDirListing()
        -- discover() runs again on every menu open, so say each of these once, not every time.
        if not fallback then
            if not warnedNoList then
                warnedNoList = true
                log("could not list the Mods folder, and the folder listing fallback found nothing either")
            end
            return
        end
        if not saidDirect then
            saidDirect = true
            log("listed the Mods folder directly: " .. tostring(root))
        end
        for i, entry in ipairs(fallback) do
            if i <= 100 then addMod(list, byId, entry.folder, entry.path) end
        end
        table.sort(list, function(a, b) return a.name:lower() < b.name:lower() end)
        mods, modsById = list, byId
        for _, m in ipairs(mods) do publishAll(m) end
        return
    end
    local count = 0
    for folder, sub in pairs(dirT) do
        if type(sub) == "table" and not tostring(folder):find("^__") then
            local has = false
            for _, f in pairs(sub.__files or {}) do
                local okN, n = pcall(function() return tostring(f.__name) end)
                if okN then
                    local low = n:lower()
                    for _, fname in ipairs(SCHEMA_FILES) do
                        if low == fname then has = true end
                    end
                end
            end
            if has and count < 100 then
                count = count + 1
                addMod(list, byId, folder, sub.__absolute_path)
            end
        end
    end
    table.sort(list, function(a, b) return a.name:lower() < b.name:lower() end)
    mods, modsById = list, byId
    for _, m in ipairs(mods) do publishAll(m) end
end

-- Keys --------------------------------------------------------------------------------------------
-- Config files use UE4SS key names (HOME, PAGE_UP, F8). The key picker uses Unreal names (Home, PageUp).
-- The numpad is the one family where the two naming schemes disagree on more than case: UE4SS says
-- NUM_SEVEN, Unreal says NumPadSeven, and the generic rule produced "NumSeven", which the key picker
-- does not know. Every numpad bind set from the menu was silently dead (found in game 2026-09-22).
local NUMPAD = {
    NUM_ZERO = "NumPadZero", NUM_ONE = "NumPadOne", NUM_TWO = "NumPadTwo", NUM_THREE = "NumPadThree",
    NUM_FOUR = "NumPadFour", NUM_FIVE = "NumPadFive", NUM_SIX = "NumPadSix", NUM_SEVEN = "NumPadSeven",
    NUM_EIGHT = "NumPadEight", NUM_NINE = "NumPadNine",
    NUM_PERIOD = "Decimal", NUM_PLUS = "Add", NUM_MINUS = "Subtract", NUM_ASTERISK = "Multiply",
    NUM_SLASH = "Divide", NUM_LOCK = "NumLock",
}
local FROM_NUMPAD = {}
for k, v in pairs(NUMPAD) do FROM_NUMPAD[v] = k end

local function toUnrealKey(name)
    if not name or name == "" or name:lower() == "none" then return "None" end
    if name:match("^F%d+$") then return name end
    if NUMPAD[name:upper()] then return NUMPAD[name:upper()] end
    local parts = {}
    for p in name:gmatch("[^_]+") do parts[#parts + 1] = p:sub(1, 1):upper() .. p:sub(2):lower() end
    return table.concat(parts)
end

local function fromUnrealKey(name)
    if not name or name == "" or name == "None" then return "none" end
    if name:match("^F%d+$") then return name end
    if FROM_NUMPAD[name] then return FROM_NUMPAD[name] end
    return (name:gsub("(%l)(%u)", "%1_%2"):gsub("(%a)(%d)", "%1_%2"):upper())
end

-- Pause menu entry -------------------------------------------------------------------------------
-- Same block as our other mods (mods/_shared/pausemenu.lua).
-- The local, in-world player controller (never the front-end one, never a remote player's).
-- FindAllOf walks every object in the game (about 50 ms on the game thread, measured 2026-09-17),
-- so the controller is cached and a missing one is looked for at most every 3 seconds.
local cachedPC, nextPCScan = nil, 0
local function localPC()
    if cachedPC and valid(cachedPC) then
        local okL, isLocal = pcall(function() return cachedPC:IsLocalController() end)
        if okL and isLocal then return cachedPC end
    end
    cachedPC = nil
    local now = os.clock()
    if now < nextPCScan then return nil end
    nextPCScan = now + 3
    local ok, all = pcall(FindAllOf, "PlayerController")
    if not ok or not all then return nil end
    for _, pc in ipairs(all) do
        if valid(pc) then
            local okN, n = pcall(function() return pc:GetFullName() end)
            local okL, isLocal = pcall(function() return pc:IsLocalController() end)
            if okN and not tostring(n):find("MainMenu", 1, true) and okL and isLocal then cachedPC = pc; return pc end
        end
    end
    return nil
end

-- The game tells every controller when it gets its pawn: remember the local in-world one, so localPC()
-- rarely needs its object scan.
pcall(RegisterHook, "/Script/Engine.PlayerController:ClientRestart", function(self)
    local pc = get(function() return self:get() end)
    if not valid(pc) then return end
    local isLocal = get(function() return pc:IsLocalController() end)
    local n = get(function() return pc:GetFullName() end) or ""
    if isLocal and not tostring(n):find("MainMenu", 1, true) then cachedPC = pc end
end)

-- Any local controller, including the main menu's, so the menu also opens from the title screen.
local function anyPC()
    local pc = localPC()
    if pc then return pc end
    local ok, all = pcall(FindAllOf, "PlayerController")
    if not ok or not all then return nil end
    for _, p in ipairs(all) do
        local okL, isLocal = pcall(function() return p:IsLocalController() end)
        if valid(p) and okL and isLocal then return p end
    end
    return nil
end

local MENU = { label = "MOD", onOpen = nil, onClose = nil, labelFn = nil, shownLabel = nil, btn = nil, btnName = nil, pm = nil, closeName = nil, pending = nil, hooked = false, wait = 0, checkN = 0, broken = false }

-- Controller support (1.0.12). A pad's A reaches CommonButtonBase:HandleButtonClicked from C++, so the UE4SS hook
-- that the mouse path relies on never sees it (measured 2026-09-29: 0 hooks fire for a pad click, even on the
-- game's own RESUME). But a SELECTABLE button does get selected by it, so pad presses are read by polling
-- GetSelected. The pad panel is docked inside the pause menu, where the game's own pad navigation reaches it,
-- with explicit navigation links (the pause list stops at its edges). Mouse, keyboard and the menu key keep the
-- overlay exactly as before. Functions are filled in next to the panel code below.
local PAD = { X = 600, Y = 180, W = 1260, H = 730, seen = false,
              HINT = "Controller: press right to move into the menu. A selects, B closes." }
local ALLCAPS = "/Game/UI/Common/WBP_DomAllCapsButton"

local function makeGameButton(pc, label, like)
    local cls = nil
    pcall(function() LoadAsset(ALLCAPS) end)
    pcall(function() cls = StaticFindObject(ALLCAPS .. ".WBP_DomAllCapsButton_C") end)
    if not valid(cls) then return nil end
    local wbl = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
    local b = nil
    pcall(function() b = wbl:Create(pc, cls, pc) end)
    if not valid(b) then return nil end
    if valid(like) then
        pcall(function() b:SetStyle(like.Style) end)
        pcall(function() b:SetTextTransformPolicy(like.TextTransformPolicy) end)
        pcall(function() b.bCenterAlignText = like.bCenterAlignText end)
        pcall(function() b.LeftAlignTextPadding = like.LeftAlignTextPadding end)
        pcall(function() b.bScrollText = like.bScrollText end)
    end
    pcall(function() b:SetLabelText(FText(label)) end)
    return b
end

-- The game creates its pause menu the first time Esc is pressed. Searching for it with FindFirstOf
-- walks every object (35-50 ms on the game thread), so instead the game tells us when one is created
-- (the callback only stores its path), plus one fallback search shortly after Esc. Paths, not objects:
-- a menu made just before a map load is freed with its world, and a kept object would then be freed memory.
local pauseSeen, pauseKnown, pauseLookAt = {}, nil, 0
pcall(NotifyOnNewObject, "/Script/Dominion.PauseMenuScreen", function(obj)
    local okN, n = pcall(function() return obj:GetFullName() end)
    local path = okN and tostring(n):match("^%S+%s+(.+)$")       -- "Class /Path:Object" -> "/Path:Object"
    if path then pauseSeen[#pauseSeen + 1] = path end
end)
pcall(RegisterKeyBind, Key.ESCAPE, function() pauseLookAt = os.clock() + 0.5 end)
local function usablePause(pm)
    if not valid(pm) then return false end
    local okN, n = pcall(function() return pm:GetFName():ToString() end)
    return okN and not tostring(n):find("^Default__")
end
local function findPauseMenu()
    if valid(MENU.pm) then return MENU.pm end
    while #pauseSeen > 0 do                            -- newest first
        local path = table.remove(pauseSeen)
        local pm = get(function() return StaticFindObject(path) end)
        if usablePause(pm) then pauseSeen = {}; pauseKnown = pm end
    end
    if usablePause(pauseKnown) then return pauseKnown end
    if pauseLookAt > 0 and os.clock() >= pauseLookAt then
        pauseLookAt = 0
        local ok, pm = pcall(FindFirstOf, "WBP_PauseMenuScreen_C")
        if ok and usablePause(pm) then pauseKnown = pm; return pm end
    end
    return nil
end

-- Clicks reach MODS through the single click hook registered in hookPanel().
local clickHookOk = nil
local function hookClicks()
    if MENU.hooked then return end
    MENU.hooked = true
    if clickHookOk == false then log("could not watch menu clicks; use the key instead") end
end
local function menuClicked(n)
    if n == MENU.btnName then MENU.pending = "open"
    elseif MENU.closeName and n == MENU.closeName then MENU.pending = "close" end
end

local function menuHas(box, w)
    local ok, idx = pcall(function() return box:GetChildIndex(w) end)
    return ok and type(idx) == "number" and idx >= 0
end

local function ensureMenuButton()
    if valid(MENU.pm) and valid(MENU.btn) then
        -- Still in place? Asked every 4th tick (1 s), not every tick: the answer only changes when the
        -- game rebuilds its pause list, and MODS then comes back a second later at most.
        MENU.checkN = MENU.checkN + 1
        if MENU.checkN % 4 ~= 0 then return end
        local box = MENU.pm.VerticalBox_PauseMenu
        if valid(box) and menuHas(box, MENU.btn) then
            if MENU.labelFn then
                local l = MENU.labelFn()
                if l ~= MENU.shownLabel then pcall(function() MENU.btn:SetLabelText(FText(l)) end); MENU.shownLabel = l end
            end
            return
        end
    end
    if MENU.broken then return end
    if MENU.wait > 0 then MENU.wait = MENU.wait - 1; return end
    MENU.wait = 4
    MENU.pm = nil
    -- The pause menu is found without scanning objects (see findPauseMenu), and its owning player is the
    -- controller to build with. Asking localPC() first, as before, ran FindAllOf("PlayerController")
    -- (about 50 ms) every 3 seconds for as long as the game sat on the title screen.
    local pm = findPauseMenu()
    if not pm then return end
    local pc = get(function() return pm:GetOwningPlayer() end)
    if not valid(pc) then pc = localPC() end
    if not pc then return end
    local box = pm.VerticalBox_PauseMenu
    if not valid(box) then return end
    local label = MENU.labelFn and MENU.labelFn() or MENU.label
    local b = makeGameButton(pc, label, pm.SettingsButton)
    if not b then return end
    local own = {}
    for _, name in ipairs({ "ResumeButton", "AgilityCourseSection", "PlayerListButton", "WorldDetails",
                            "SettingsButton", "ExitToMainMenuButton", "ExitToDesktopMenu" }) do
        local w = pm[name]
        if valid(w) then own[w:GetFullName()] = true end
    end
    local function sortKey(w)
        local okL, l = pcall(function() return w.ButtonLabel:ToString() end)
        l = okL and tostring(l) or ""
        return (l:gsub("^SHOW ", ""):gsub("^HIDE ", ""))
    end
    local extras = { b }
    for i = box:GetChildrenCount() - 1, 0, -1 do
        local c = box:GetChildAt(i)
        if valid(c) and not own[c:GetFullName()] then extras[#extras + 1] = c end
    end
    local exits = {}
    for _, name in ipairs({ "ExitToMainMenuButton", "ExitToDesktopMenu" }) do
        local e = pm[name]
        if valid(e) and menuHas(box, e) then exits[#exits + 1] = e end
    end
    for _, w in ipairs(extras) do if w ~= b then pcall(function() box:RemoveChild(w) end) end end
    for _, e in ipairs(exits) do pcall(function() box:RemoveChild(e) end) end
    table.sort(extras, function(x, y) return sortKey(x) < sortKey(y) end)
    for _, w in ipairs(extras) do pcall(function() box:AddChildToVerticalBox(w) end) end
    for _, e in ipairs(exits) do pcall(function() box:AddChildToVerticalBox(e) end) end
    MENU.pm, MENU.btn, MENU.btnName = pm, b, b:GetFullName()
    if not menuHas(box, b) then
        MENU.broken = true
        log("pause menu button could not be confirmed; use the key instead")
        return
    end
    hookClicks()
    pcall(function() b:SetIsSelectable(true) end)      -- after it is built: a pad's A then selects it (PAD.pollMods)
    MENU.shownLabel = label
    log("added " .. MENU.label .. " to the pause menu")
end

local function menuTick()
    if MENU.pending == "open" then
        MENU.pending = "open2"
        PAD.unselect(MENU.btn)                         -- the mouse click selected it too; not a pad press
        pcall(function() MENU.pm:Resume() end)
    elseif MENU.pending == "open2" then
        MENU.pending = nil
        local ok, err = pcall(MENU.onOpen)
        if not ok then log("menu error: " .. tostring(err)) end
    elseif MENU.pending == "close" then
        MENU.pending = nil
        if MENU.onClose then pcall(MENU.onClose) end
    elseif cfg.ShowInPauseMenu then
        ensureMenuButton()
        PAD.pollMods()
    end
end

-- Panel -------------------------------------------------------------------------------------------
local GOLD  = { R = 0.86, G = 0.72, B = 0.42, A = 1.0 }
local CREAM = { R = 0.90, G = 0.86, B = 0.78, A = 1.0 }
local GREY  = { R = 0.62, G = 0.60, B = 0.56, A = 1.0 }
local RED   = { R = 0.90, G = 0.40, B = 0.35, A = 1.0 }

local function loadClass(pkg)
    local asset = pkg:match("([^/]+)$")
    pcall(function() LoadAsset(pkg) end)
    local c = nil
    pcall(function() c = StaticFindObject(pkg .. "." .. asset .. "_C") end)
    return valid(c) and c or nil
end

local function construct(cls, tree)
    local c = StaticFindObject("/Script/UMG." .. cls)
    return StaticConstructObject(c, tree)
end

local panel = { open = false, page = 1, rows = {}, buttons = {}, pending = nil, dirty = {}, lastEdit = 0 }
local buildModList   -- defined below the page builder

-- Whole-panel size. A render transform scales the frame and everything inside it together, which is
-- the only approach that keeps the layout intact: the panel's width comes from fixed SizeBox
-- overrides (LEFT, rightW, the 440-wide label column), not from a size value, so a font setting
-- would leave the boxes behind.
--
-- Two things differ from the same setting in XP Tracker, and both matter:
--
--  * The pivot is the centre, not (0,0). XP Tracker anchors its panel to a corner the position
--    sliders set, so it grows down and right from there. This panel is re-centred every time it
--    opens, so it has to grow from its middle or it drifts off centre as it scales.
--  * The value is clamped to what actually fits. At 100% the panel is already 1500x920, most of a
--    1080p screen, so an unclamped 200% would push CLOSE and RESET past the edge with no way to
--    reach them. maxFit below makes that unreachable regardless of what is in config.txt.
local function fitScale(s, vw, vh, w, h)
    if s < 50 then s = 50 elseif s > 200 then s = 200 end
    s = s / 100
    if w > 0 and h > 0 then
        local maxFit = math.min((vw - 40) / w, (vh - 40) / h)
        if maxFit > 0 and s > maxFit then s = maxFit end
    end
    return s
end

local function applyScale(p)
    if not valid(p.frame) or p.mode == "pad" then return end   -- the docked pad panel keeps the menu's layout
    local s = fitScale(tonumber(cfg.PanelScale) or 100, p.vw or 1920, p.vh or 1080, p.w or 0, p.h or 0)
    pcall(function() p.frame:SetRenderTransformPivot({ X = 0.5, Y = 0.5 }) end)
    pcall(function() p.frame:SetRenderScale({ X = s, Y = s }) end)
end

local function newText(tree, cls, s, size, color)
    local tb = StaticConstructObject(cls, tree)
    pcall(function() local f = tb.Font; f.Size = size; tb:SetFont(f) end)
    pcall(function() tb:SetColorAndOpacity({ SpecifiedColor = color, ColorUseRule = 0 }) end)
    pcall(function() tb:SetAutoWrapText(true) end)
    pcall(function() tb:SetText(FText(s)) end)
    return tb
end

local function setInputUI(pc, focusWidget, on)
    local wbl = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
    pcall(function() pc.bShowMouseCursor = on end)
    if on then
        -- UI only while a panel is open. With game-and-UI, a click that lands on the window but not on a
        -- button falls through to the game and swings your weapon, which near a cliff can walk you off it
        -- (reported by CabolaDK, 2026-09-17). Esc still closes the panel: that is a UE4SS key bind, not game input.
        local okUI = pcall(function() wbl:SetInputMode_UIOnlyEx(pc, focusWidget, 0, false) end)
        if not okUI then pcall(function() wbl:SetInputMode_GameAndUIEx(pc, focusWidget, 0, false, false) end) end
    else
        pcall(function() wbl:SetInputMode_GameOnly(pc, false) end)
    end
end

-- Dark, game-coloured look for the native text box and key picker (they default to white).
-- Must run before the widget is added to a panel (the style is copied when it is built).
-- Verified in game 2026-09-16: writing the style struct back works for both widget types.
local function styleInput(w)
    if not valid(w) then return end
    local function col(r, g, b, a) return { SpecifiedColor = { R = r, G = g, B = b, A = a }, ColorUseRule = 0 } end
    pcall(function()
        local st = w.WidgetStyle
        local cls = w:GetClass():GetFName():ToString()
        if cls == "EditableTextBox" then
            st.BackgroundColor = col(0.03, 0.028, 0.025, 1.0)
            st.ForegroundColor = col(CREAM.R, CREAM.G, CREAM.B, 1.0)
            st.FocusedForegroundColor = col(1.0, 0.95, 0.85, 1.0)
            for _, name in ipairs({ "BackgroundImageNormal", "BackgroundImageHovered", "BackgroundImageFocused" }) do
                local br = st[name]
                br.TintColor = col(name == "BackgroundImageNormal" and 0.06 or 0.10, 0.055, 0.05, 1.0)
                st[name] = br
            end
        else
            for _, name in ipairs({ "Normal", "Hovered", "Pressed" }) do
                local br = st[name]
                local v = name == "Normal" and 0.05 or (name == "Hovered" and 0.12 or 0.08)
                br.TintColor = col(v, v * 0.92, v * 0.85, 1.0)
                st[name] = br
            end
            pcall(function() w:SetNoKeySpecifiedText(FText("None")) end)
            pcall(function() w:SetKeySelectionText(FText("Press a key...")) end)
            local ts = w.TextStyle
            ts.ColorAndOpacity = col(GOLD.R, GOLD.G, GOLD.B, 1.0)
            w.TextStyle = ts
        end
        w.WidgetStyle = st
    end)
end

local function sized(tree, w, width, height)
    local sz = construct("SizeBox", tree)
    if width then pcall(function() sz:SetWidthOverride(width) end) end
    if height then pcall(function() sz:SetHeightOverride(height) end) end
    sz:AddChild(w)
    return sz
end

local function readWidget(row)
    local s, w = row.setting, row.widget
    if not valid(w) then return nil end
    if s.type == "toggle" then
        local ok, v = pcall(function() return w.InputCheckBox:IsChecked() end)
        if ok and type(v) == "boolean" then return v end
    elseif s.type == "slider" then
        local ok, v = pcall(function() return w:GetValue() end)
        if ok and type(v) == "number" then return round(v, s.decimals) end
    elseif s.type == "choice" then
        if row.cycle then return row.cycleValue end
        local ok, t = pcall(function() return w.SelectionDisplayText:GetText():ToString() end)
        if ok and t then
            for _, o in ipairs(s.options) do if o:lower() == tostring(t):lower() then return o end end
        end
    elseif s.type == "key" then
        local ok, n = pcall(function() return w.SelectedKey.Key.KeyName:ToString() end)
        if ok and n then return fromUnrealKey(tostring(n)) end
    elseif s.type == "text" then
        local ok, t = pcall(function() return w:GetText():ToString() end)
        if ok and t then return tostring(t):sub(1, s.maxLength) end
    end
    return nil
end

local function writeWidget(row, v)
    local s, w = row.setting, row.widget
    if s.type == "toggle" then pcall(function() w:SetValue(v) end)
    elseif s.type == "slider" then
        pcall(function() w:SetValue(v) end)
        pcall(function() w:UpdateValueText() end)
    elseif s.type == "choice" then
        if row.cycle then
            row.cycleValue = v
            pcall(function() w:SetLabelText(FText(s.label .. ":  " .. v)) end)
        else
            for i, o in ipairs(s.options) do
                if o == v then pcall(function() w:SetSelectedIndex(i - 1) end) end
            end
        end
    elseif s.type == "key" then
        pcall(function() w:SetSelectedKey({ Key = { KeyName = FName(toUnrealKey(v)) } }) end)
    elseif s.type == "text" then
        pcall(function() w:SetText(FText(v)) end)
    end
end

-- Settings that only apply after a restart get a * after their label.
local function rowLabel(s) return s.label .. (s.restart and "  *" or "") end

local function labeledRow(ui, s, control, controlWidth)
    local row = construct("HorizontalBox", ui.tree)
    row:AddChildToHorizontalBox(sized(ui.tree, newText(ui.tree, ui.textC, rowLabel(s), 18, CREAM), 440, 56))
    row:AddChildToHorizontalBox(sized(ui.tree, control, controlWidth, 50))
    return row
end

local function fillPage(ui, idx)
    local scroll = ui.scroll
    pcall(function() scroll:ClearChildren() end)
    pcall(function() scroll:SetScrollOffset(0) end)
    panel.rows, panel.buttons.actions = {}, {}
    panel.order = {}                                        -- every drawn row in screen order (controller links)
    local m = mods[idx]
    if not m then
        pcall(function() ui.title:SetText(FText("No mods to configure")) end)
        scroll:AddChild(newText(ui.tree, ui.textC,
            "No installed mod has a modmenu.json yet. Mod authors: see README.md in the ModMenu folder.", 18, GREY))
        return
    end
    local sub = m.name
    if m.version then sub = sub .. "   v" .. m.version end
    if m.author then sub = sub .. "   by " .. m.author end
    pcall(function() ui.title:SetText(FText(sub)) end)
    if m.description then scroll:AddChild(newText(ui.tree, ui.textC, m.description, 16, GREY)) end
    for _, e in ipairs(m.errors) do scroll:AddChild(newText(ui.tree, ui.textC, "! " .. e, 16, RED)) end
    for _, st in ipairs(m.settings) do
        if st.restart and not st.locked then
            scroll:AddChild(newText(ui.tree, ui.textC, "* applies after restarting the game", 16, GREY))
            break
        end
    end

    local pc, wbl = panel.pc, StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
    local W = ui.rightW
    for _, s in ipairs(m.settings) do
        local row = { setting = s }
        local holder = nil
        if s.locked then
            holder = nil                                        -- could not be read from the mod's file; error shown above
        elseif s.type == "header" then
            holder = newText(ui.tree, ui.textC, s.label, 24, GOLD)
        elseif s.type == "toggle" and ui.checkC then
            local w = wbl:Create(pc, ui.checkC, pc)
            pcall(function() w.LabelText = FText(rowLabel(s)) end)
            row.widget = w
            holder = sized(ui.tree, w, W, 56)
        elseif s.type == "slider" and ui.sliderC then
            local w = wbl:Create(pc, ui.sliderC, pc)
            pcall(function() w.InitialMinSliderValue = s.min end)
            pcall(function() w.InitialMaxSliderValue = s.max end)
            pcall(function() w.AmountDecimalPlacesToShow = s.decimals end)
            pcall(function() w.bShowPostfix = s.suffix ~= "" end)
            pcall(function() w.Postfix = FString(s.suffix) end)
            pcall(function() w.LabelText = FText(rowLabel(s)) end)
            row.widget = w
            holder = sized(ui.tree, w, W, 56)
        elseif s.type == "choice" then
            -- Always the cycling game button, never the game's carousel (WBP_SelectorWidget_WithLabel).
            -- Filling the carousel's SelectableChoices (an array of FText) from Lua corrupted the game's
            -- memory: a page with one choice row crashed within 3-6 opens (heap "realloc an unrecognized
            -- block", or an access violation at a heap address), the same page without it never did.
            -- Found 2026-09-25 building Weather Control's page.
            local b = makeGameButton(pc, s.label, ui.like)
            row.widget, row.cycle = b, true
            if b then panel.buttons.actions[b:GetFullName()] = { cycle = row } end
            holder = b and sized(ui.tree, b, W, 56) or nil
        elseif s.type == "key" then
            local w = construct("InputKeySelector", ui.tree)
            styleInput(w)
            row.widget = w
            holder = labeledRow(ui, s, w, 360)
        elseif s.type == "text" then
            local w = construct("EditableTextBox", ui.tree)
            styleInput(w)
            row.widget = w
            holder = labeledRow(ui, s, w, W - 460)
        elseif s.type == "button" then
            local b = makeGameButton(pc, s.label, ui.like)
            if b then
                panel.buttons.actions[b:GetFullName()] = { mod = m, action = s.action }
                holder = sized(ui.tree, b, 420, 56)
                row.button = b
            end
        end
        if holder then
            scroll:AddChild(holder)
            row.holder = holder
            panel.order[#panel.order + 1] = row
            if row.widget then
                panel.rows[#panel.rows + 1] = row
            elseif s.tooltip or s.restart then
                panel.rows[#panel.rows + 1] = row
            end
        end
    end
    -- Values and labels after the widgets are constructed (construction resets them).
    for _, row in ipairs(panel.rows) do
        local s = row.setting
        if row.widget and s.key then
            if s.type == "slider" then
                pcall(function() row.widget.InputSlider:SetMinValue(s.min) end)
                pcall(function() row.widget.InputSlider:SetMaxValue(s.max) end)
                pcall(function() row.widget.InputSlider:SetStepSize(s.step) end)
            end
            if not row.cycle then
                pcall(function() row.widget.InputLabelButton.LabelText:SetText(FText(rowLabel(s))) end)
            end
            writeWidget(row, m.values[s.key])
            row.last = m.values[s.key]
        end
    end
    if #m.settings == 0 and #m.errors == 0 then
        scroll:AddChild(newText(ui.tree, ui.textC, "This mod has no settings.", 18, GREY))
    end
    if panel.mode == "pad" then
        local okP, e = pcall(PAD.afterFill, ui)
        if not okP then log("controller links: " .. tostring(e)) end
    end
end

-- Left column: mod buttons, filtered by the search box (mod name, setting labels and keys).
buildModList = function(ui, query)
    pcall(function() ui.leftScroll:ClearChildren() end)
    panel.buttons.mods = {}
    ui.modBtns = {}                                         -- in list order, for the controller links
    local q = (query or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
    local shown = 0
    for i, m in ipairs(mods) do
        local hit = q == "" or m.name:lower():find(q, 1, true) ~= nil
        if not hit then
            for _, st in ipairs(m.settings) do
                if (st.label and st.label:lower():find(q, 1, true)) or (st.key and st.key:lower():find(q, 1, true)) then hit = true; break end
            end
        end
        if hit then
            local b = makeGameButton(panel.pc, m.name, ui.like)
            if b then
                ui.leftScroll:AddChild(sized(ui.tree, b, ui.leftW - 20, 56))
                panel.buttons.mods[b:GetFullName()] = i
                ui.modBtns[#ui.modBtns + 1] = { w = b, idx = i }
                shown = shown + 1
            end
        end
    end
    if shown == 0 then ui.leftScroll:AddChild(newText(ui.tree, ui.textC, "No matches", 16, GREY)) end
    ui.query = query or ""
    if panel.mode == "pad" and panel.ui == ui then pcall(PAD.afterFill, ui) end
end

-- A failed save (file locked by an editor or antivirus) is retried every 5 seconds, up to 5 times,
-- instead of being dropped, which lost the player's change silently at the next restart.
local saveFails = {}
local function saveDirty(force)
    local now = os.clock()
    for id in pairs(panel.dirty) do
        local m = modsById[id]
        local f = saveFails[id]
        if not m then
            panel.dirty[id] = nil
        elseif (force or now - panel.lastEdit > 1.0) and (not f or force or now >= f.retryAt) then
            local ok, res = pcall(saveValues, m)
            if ok and res then
                log("saved " .. m.name)
                panel.dirty[id], saveFails[id] = nil, nil
            else
                f = f or { n = 0 }
                f.n, f.retryAt = f.n + 1, now + 5
                saveFails[id] = f
                log("could not save settings for " .. m.name .. " (try " .. f.n .. "): " .. tostring(res))
                if f.n >= 5 then panel.dirty[id], saveFails[id] = nil, nil end
            end
        end
    end
end

local function closePanel(keepInput)
    if not panel.open then return end
    saveDirty(true)
    if panel.frame then pcall(function() panel.frame:RemoveFromParent() end) end
    -- In a world, hand input back to the game. Outside one (title screen) the game's own menus need the
    -- cursor and UI input, so leave them as they were.
    if panel.mode == "pad" then
        PAD.unwire()                                   -- the pause menu owns input there; only our links go
        PAD.refocus(panel.pm)
    elseif panel.pc and not keepInput and panel.inWorld then setInputUI(panel.pc, nil, false) end
    panel.open, panel.frame, panel.ui, panel.rows = false, nil, nil, {}
    panel.buttons = {}
    panel.mode, panel.padBtns, panel.order, panel.pm = nil, nil, nil, nil
end

local function openPanel(mode)                     -- mode "pad": docked in the pause menu for a controller
    if panel.open then return end
    local pc = anyPC()
    if not pc then log("no local player controller yet"); return end
    panel.inWorld = localPC() ~= nil
    discover()

    local wbl = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
    local panelC = loadClass("/Game/UI/Panels/WBP_Panel")
    local textC = loadClass("/Game/UI/Common/WBP_DomTextBlock")
    if not (panelC and textC) then log("the game's UI pieces were not found"); return end

    local vw, vh = 1920, 1080
    pcall(function()
        local wll = StaticFindObject("/Script/UMG.Default__WidgetLayoutLibrary")
        local size, scale = wll:GetViewportSize(pc), wll:GetViewportScale(pc)
        -- size.X > 0 matters: for the first seconds after launch the viewport reports 0x0 while
        -- still returning a sensible-looking scale, and dividing that through built a -40x-40
        -- panel (seen in ScaleHitProbe, 2026-09-20). Fall back to the 1920x1080 defaults instead.
        if size and scale and scale > 0 and size.X > 0 and size.Y > 0 then
            vw, vh = size.X / scale, size.Y / scale
        end
    end)
    local W, H = math.min(1500, vw - 40), math.min(920, vh - 40)
    if mode == "pad" then W, H = PAD.W, PAD.H end    -- right of the pause list, in the menu's 1920x1080 units
    local LEFT = 330
    panel.pc = pc
    local frame = wbl:Create(pc, panelC, pc)
    local tree = frame.WidgetTree
    local ui = { tree = tree, textC = textC, frame = frame, rightW = W - LEFT - 140,
                 checkC = loadClass("/Game/UI/Settings/WBP_Settings_Checkbox"),
                 sliderC = loadClass("/Game/UI/Settings/WBP_Settings_Slider"),
                 like = (findPauseMenu() or {}).SettingsButton }
    panel.buttons = { mods = {}, actions = {} }

    local vb = construct("VerticalBox", tree)
    frame.PanelContent:AddChild(vb)
    vb:AddChildToVerticalBox(newText(tree, textC, "MOD SETTINGS", 30, GOLD))

    local body = construct("HorizontalBox", tree)
    local left = construct("VerticalBox", tree)
    ui.search = construct("EditableTextBox", tree)
    pcall(function() ui.search:SetHintText(FText("Search")) end)
    styleInput(ui.search)
    left:AddChildToVerticalBox(sized(tree, ui.search, LEFT - 20, 44))
    ui.leftScroll = construct("ScrollBox", tree)
    ui.leftW = LEFT
    left:AddChildToVerticalBox(sized(tree, ui.leftScroll, LEFT, H - 300))
    body:AddChildToHorizontalBox(left)
    buildModList(ui, "")

    local right = construct("VerticalBox", tree)
    ui.title = newText(tree, textC, "", 20, CREAM)
    right:AddChildToVerticalBox(ui.title)
    ui.scroll = construct("ScrollBox", tree)
    right:AddChildToVerticalBox(sized(tree, ui.scroll, ui.rightW + 20, H - 290))
    body:AddChildToHorizontalBox(right)
    vb:AddChildToVerticalBox(body)

    ui.hint = newText(tree, textC, "", 16, GREY)
    vb:AddChildToVerticalBox(sized(tree, ui.hint, W - 100, 44))

    local foot = construct("HorizontalBox", tree)
    local resetB = makeGameButton(pc, "RESET TO DEFAULTS", ui.like)
    local closeB = makeGameButton(pc, "CLOSE", ui.like)
    if resetB then foot:AddChildToHorizontalBox(sized(tree, resetB, 380, 56)); panel.buttons.reset = resetB:GetFullName() end
    if closeB then foot:AddChildToHorizontalBox(sized(tree, closeB, 300, 56)); panel.buttons.close = closeB:GetFullName() end
    vb:AddChildToVerticalBox(foot)
    ui.resetB, ui.closeB = resetB, closeB

    if mode == "pad" then
        -- Docked in THIS call: a frame docked a call later crashed the Lua state in testing (2026-09-29).
        local okD, why = PAD.dock(frame, W, H)
        if not okD then log("controller panel not opened: " .. tostring(why)); pcall(function() frame:RemoveFromParent() end); return end
    else
        frame:AddToViewport(9000)
        pcall(function() frame:SetPositionInViewport({ X = (vw - W) / 2, Y = (vh - H) / 2 }, false) end)
        pcall(function() frame:SetDesiredSizeInViewport({ X = W, Y = H }) end)
    end
    panel.frame, panel.ui, panel.open = frame, ui, true
    panel.mode = mode == "pad" and "pad" or nil
    -- Kept so the size slider can re-clamp against this screen without reopening the panel.
    panel.vw, panel.vh, panel.w, panel.h = vw, vh, W, H
    applyScale(panel)
    if panel.page > #mods then panel.page = 1 end
    local ok, e = pcall(fillPage, ui, panel.page)
    if not ok then log("page error: " .. tostring(e)) end
    if panel.mode == "pad" then pcall(function() ui.hint:SetText(FText(PAD.HINT)) end)
    else setInputUI(pc, frame, true) end
    log("opened (" .. #mods .. " mods" .. (panel.mode == "pad" and ", controller" or "") .. ")")
end

local function resetMod(m)
    for _, s in ipairs(m.settings) do if s.key then m.values[s.key] = s.default end end
    m.rev = m.rev + 1
    publishAll(m)
    if m.id == "ModMenu" then
        for k, v in pairs(m.values) do if cfg[k] ~= nil then cfg[k] = v end end
        applyScale(panel)
    end
    panel.dirty[m.id] = true
    panel.lastEdit = os.clock()
    if panel.open and panel.ui then pcall(fillPage, panel.ui, panel.page) end
end

-- One dispatch for a panel button, reached by the mouse (the hook below) and by a pad (PAD.pollPanel).
local function clickPanelButton(n)
    local b = panel.buttons
    if b.mods and b.mods[n] then panel.pending = { page = b.mods[n] }
    elseif b.actions and b.actions[n] then panel.pending = { action = b.actions[n] }
    elseif n == b.reset then panel.pending = { reset = true }
    elseif n == b.close then panel.pending = { close = true } end
end

-- One hook for every button click in the game (was two). The name is read once, and only while one of
-- our buttons exists.
local panelHooked = false
local function hookPanel()
    if panelHooked then return end
    panelHooked = true
    clickHookOk = pcall(RegisterHook, "/Script/CommonUI.CommonButtonBase:HandleButtonClicked", function(self)
        if not panel.open and not MENU.btnName then return end
        local okN, n = pcall(function() return self:get():GetFullName() end)
        if not okN then return end
        if panel.open then clickPanelButton(n) end
        menuClicked(n)
    end)
    if not clickHookOk then log("could not watch button clicks; use the menu key instead") end
end

-- Controller path (PAD table and constants: next to MENU). Measured in game 2026-09-29, game in front
-- (data/cmd/mm2 passes 3-8): pad A selects a selectable CommonUI button with no hook firing; SetIsSelected(false)
-- is ignored on these buttons but toggling SetIsSelectable clears it; explicit navigation links carry pad focus
-- from the pause list into a docked panel; the game's checkbox takes A and its slider takes left/right; B closes
-- the pause menu.
function PAD.unselect(b)
    if not valid(b) then return end
    pcall(function() b:SetIsSelectable(false) end)
    pcall(function() b:SetIsSelectable(true) end)
end

-- MODS is selected, the mouse hook has not claimed it after a full tick: that was a pad press.
function PAD.pollMods()
    if panel.open or not valid(MENU.btn) then PAD.seen = false; return end
    local ok, sel = pcall(function() return MENU.btn:GetSelected() end)
    if not (ok and sel) then PAD.seen = false; return end
    if MENU.pending then return end
    if not PAD.seen then PAD.seen = true; return end
    PAD.seen = false
    PAD.unselect(MENU.btn)
    local okO, err = pcall(openPanel, "pad")
    if not okO then log("controller panel error: " .. tostring(err)) end
end

-- Dock the frame into the open pause menu: its root is a BackgroundBlur holding a CanvasPanel.
function PAD.dock(frame, W, H)
    local pm = findPauseMenu()
    if not valid(pm) then return false, "no pause menu" end
    local okA, act = pcall(function() return pm:IsActivated() end)
    if not (okA and act) then return false, "the pause menu is closed" end
    local root = nil
    pcall(function() root = pm.WidgetTree.RootWidget end)
    if not valid(root) then return false, "no pause menu layout" end
    local canvas, cls = root, ""
    pcall(function() cls = root:GetClass():GetFName():ToString() end)
    if cls ~= "CanvasPanel" then pcall(function() canvas = root:GetContent() end) end
    local okS, slot = pcall(function() return canvas:AddChildToCanvas(frame) end)
    if not (okS and valid(slot)) then return false, "could not dock into the pause menu" end
    pcall(function() slot:SetPosition({ X = PAD.X, Y = PAD.Y }) end)
    pcall(function() slot:SetSize({ X = W, Y = H }) end)
    pcall(function() slot:SetZOrder(100) end)
    panel.pm = pm
    return true
end

-- After every page build: make the buttons selectable (only once the game has built them), keep them for
-- polling, and link pad navigation: MODS -> mod list -> settings column (+ RESET, CLOSE), Left goes back.
-- EUINavigation 0 Left, 1 Right, 2 Up, 3 Down. Sliders keep Left/Right for their value; key pickers and text
-- boxes need a keyboard, so they stay out of the pad path.
function PAD.afterFill(ui)
    local btns, col, cur = {}, {}, nil
    local function sel(b) if valid(b) then pcall(function() b:SetIsSelectable(true) end); btns[#btns + 1] = b end end
    local ml = ui.modBtns or {}
    for _, mb in ipairs(ml) do
        sel(mb.w)
        if mb.idx == panel.page then cur = mb.w end
    end
    cur = cur or (ml[1] and ml[1].w)
    for _, row in ipairs(panel.order or {}) do
        local s, w = row.setting, nil
        if s.locked then
            w = nil
        elseif s.type == "toggle" and valid(row.widget) then pcall(function() w = row.widget.InputCheckBox end)
        elseif s.type == "slider" and valid(row.widget) then pcall(function() w = row.widget.InputSlider end)
        elseif s.type == "choice" and row.cycle then w = row.widget; sel(w)
        elseif s.type == "button" and row.button then w = row.button; sel(w) end
        if valid(w) then col[#col + 1] = { w = w, slider = s.type == "slider" } end
    end
    for _, fb in ipairs({ ui.resetB, ui.closeB }) do if valid(fb) then sel(fb); col[#col + 1] = { w = fb } end end
    panel.padBtns = btns
    local function link(from, dir, to) if valid(from) and valid(to) then pcall(function() from:SetNavigationRuleExplicit(dir, to) end) end end
    local first = col[1] and col[1].w
    link(MENU.btn, 1, cur)
    for i, mb in ipairs(ml) do
        if i > 1 then link(mb.w, 2, ml[i - 1].w) end
        if i < #ml then link(mb.w, 3, ml[i + 1].w) end
        link(mb.w, 1, first)
        link(mb.w, 0, MENU.btn)
    end
    for i, c in ipairs(col) do
        if i > 1 then link(c.w, 2, col[i - 1].w) end
        if i < #col then link(c.w, 3, col[i + 1].w) end
        if not c.slider then link(c.w, 0, cur) end
    end
    for _, sc in ipairs({ ui.scroll, ui.leftScroll }) do
        pcall(function() sc:SetScrollWhenFocusChanges(1) end)   -- follow pad focus
        pcall(function() sc:ForceVolatile(true) end)            -- no stale rows once it scrolls (tested)
    end
end

-- A pad press on a panel button shows up as a selection: route it like a click. A mouse click in the docked
-- panel fires the hook AND selects the button; the hook's pending wins and the selection is just cleared.
function PAD.pollPanel()
    for _, b in ipairs(panel.padBtns or {}) do
        local ok, sel = pcall(function() return b:GetSelected() end)
        if ok and sel then
            PAD.unselect(b)
            local okN, n = pcall(function() return b:GetFullName() end)
            if okN and not panel.pending then clickPanelButton(n) end
            return
        end
    end
end

function PAD.unwire()
    pcall(function() MENU.btn:SetNavigationRuleBase(1, 0) end)   -- MODS gets its own Right rule back
    panel.padBtns = nil
end

-- After CLOSE the focused button is gone and the pause menu kept no focus, so the pad did nothing until B or
-- Start (test 2026-09-29). Ask the pause menu to refocus itself (its own focus, which the pad follows); if that
-- call is missing, focus MODS.
function PAD.refocus(pm)
    local okA, act = pcall(function() return pm:IsActivated() end)
    if not (okA and act) then return end
    if pcall(function() pm:RequestRefreshFocus() end) then return end
    pcall(function() MENU.btn:SetUserFocus(panel.pc) end)
    pcall(function() MENU.btn:SetKeyboardFocus() end)
end

local function panelTick()
    if not panel.open then saveDirty(false); return end
    if not valid(panel.frame) then panel.open = false; return end
    if panel.mode == "pad" then
        local okA, act = pcall(function() return panel.pm:IsActivated() end)
        if not (okA and act) then closePanel(true); return end   -- B (or RESUME) closed the pause menu: go with it
        PAD.pollPanel()
    end
    local p = panel.pending
    panel.pending = nil
    local m = mods[panel.page]
    if p then
        if p.close then closePanel(); return end
        if p.page and p.page ~= panel.page then
            saveDirty(true)
            panel.page = p.page
            local ok, e = pcall(fillPage, panel.ui, panel.page)
            if not ok then log("page error: " .. tostring(e)) end
            return
        end
        if p.reset and m then resetMod(m); return end
        if p.action then
            local a = p.action
            if a.cycle then
                local row, s = a.cycle, a.cycle.setting
                local i = 1
                for k, o in ipairs(s.options) do if o == row.cycleValue then i = k end end
                writeWidget(row, s.options[i % #s.options + 1])
            elseif a.mod then
                a.mod.actionN = a.mod.actionN + 1
                share("ModMenu." .. a.mod.id .. ".action", a.action .. "#" .. a.mod.actionN)
                log(a.mod.name .. ": " .. a.action)
            end
        end
    end
    if panel.ui and panel.ui.search then
        local okS, q = pcall(function() return panel.ui.search:GetText():ToString() end)
        if okS and q and tostring(q) ~= panel.ui.query then pcall(buildModList, panel.ui, tostring(q)) end
    end
    if not m then return end
    local hint = nil
    for _, row in ipairs(panel.rows) do
        local s = row.setting
        if row.widget and s.key then
            local v = readWidget(row)
            if v ~= nil and v ~= row.last then
                row.last = v
                if v ~= m.values[s.key] then
                    m.values[s.key] = v
                    m.rev = m.rev + 1
                    share("ModMenu." .. m.id .. "." .. s.key, v)
                    share("ModMenu." .. m.id .. ".rev", m.rev)
                    panel.dirty[m.id] = true
                    panel.lastEdit = os.clock()
                    -- Mod Menu's own settings are read from the file at startup, so a change made
                    -- here has to be mirrored into cfg or the panel would not resize until restart.
                    if m.id == "ModMenu" and cfg[s.key] ~= nil then
                        cfg[s.key] = v
                        if s.key == "PanelScale" then applyScale(panel) end
                    end
                end
            end
        end
        if not hint and (s.tooltip or s.restart) and valid(row.holder) then
            local ok, h = pcall(function() return row.holder:IsHovered() end)
            if ok and h then
                hint = s.tooltip or ""
                if s.restart then hint = (hint ~= "" and (hint .. "  ") or "") .. "Applies after restarting the game." end
            end
        end
    end
    hint = hint or (panel.mode == "pad" and PAD.HINT or "")
    if hint ~= panel.hintShown then
        panel.hintShown = hint
        pcall(function() panel.ui.hint:SetText(FText(hint)) end)
    end
    saveDirty(false)
end

-- Other mods can open the menu at their own page: SetSharedVariable("ModMenu.request.open", "<id>#<n>")
-- with n changing each time (so a repeat request is still seen).
local lastOpenReq = nil
local function requestTick()
    local ok, r = pcall(function() return ModRef:GetSharedVariable("ModMenu.request.open") end)
    if not ok or type(r) ~= "string" or r == lastOpenReq then return end
    lastOpenReq = r
    local id = r:match("^([^#]*)")
    if not panel.open then discover() end
    for i, m in ipairs(mods) do
        if m.id == id then
            if panel.open then
                if i ~= panel.page then saveDirty(true); panel.page = i; pcall(fillPage, panel.ui, i) end
            else
                panel.page = i
                openPanel()
            end
            return
        end
    end
    log("open request for unknown mod '" .. tostring(id) .. "'")
end

-- Own settings, read the same way other mods' are ---------------------------------------------------
local function loadOwnConfig()
    local root = modRoot()
    if not root then return end
    local ok, m = pcall(loadSchema, "ModMenu", root)
    if not ok or not m then return end
    for k, v in pairs(m.values) do if cfg[k] ~= nil then cfg[k] = v end end
end

-- Two copies (the original ModMenu folder and RSE-ModMenu) would both add MODS to the pause menu and both
-- write the same config files. The first copy to load claims ModMenu.instance with its folder; a second
-- copy stands down. The same folder again is a UE4SS hot reload of this copy, which is fine.
local myPath = modRoot() or "?"
do
    local ok, owner = pcall(function() return ModRef:GetSharedVariable("ModMenu.instance") end)
    if ok and type(owner) == "string" and owner ~= "" and owner ~= myPath then
        log("another Mod Menu is already loaded from " .. owner .. "; this copy (" .. myPath .. ") stays off. "
            .. "Remove one of the two folders.")
        return
    end
    share("ModMenu.instance", myPath)
end

loadOwnConfig()
share("ModMenu.version", VERSION)
pcall(discover)
hookPanel()

MENU.label = "MODS"
MENU.onOpen = function() openPanel() end
MENU.onClose = function() closePanel() end

-- Map loads pause everything until the new world has settled (the hooks are below the Esc handling).
local SETTLE = 10
local idleUntil = 0
local function paused() return os.clock() < idleUntil end

local menuKey = Key[(cfg.MenuKey or ""):upper()]
local noKey = (cfg.MenuKey or ""):lower() == "none" or cfg.MenuKey == ""
if menuKey and not noKey then
    RegisterKeyBind(menuKey, function()
        ExecuteInGameThread(function()
            if paused() then return end
            local ok, err = pcall(function() if panel.open then closePanel() else openPanel() end end)
            if not ok then log("panel error: " .. tostring(err)) end
        end)
    end)
elseif not noKey then
    log("MenuKey '" .. tostring(cfg.MenuKey) .. "' is not a recognised key; use the pause menu instead")
end

-- Esc closes the panel and normally lands in the game's pause menu, which wants the cursor. If a text
-- box had focus, the game never sees that Esc and no pause menu opens, so give input back to the game.
local escCheck = nil
RegisterKeyBind(Key.ESCAPE, function()
    ExecuteInGameThread(function()
        if panel.open then
            local inWorld, pc = panel.inWorld, panel.pc
            pcall(closePanel, true)
            if inWorld and pc then escCheck = { at = os.clock() + 0.6, pc = pc } end
        end
    end)
end)

local function escTick()
    if not escCheck or os.clock() < escCheck.at then return end
    local pc = escCheck.pc
    escCheck = nil
    local pm = findPauseMenu()
    -- IsInViewport is false even while the pause menu shows (it lives in the game's widget stack);
    -- IsActivated is true only while it is open (checked in game 2026-09-16).
    local ok, shown = pcall(function() return pm:IsActivated() end)
    if not (ok and shown) and valid(pc) and not panel.open then setInputUI(pc, nil, false) end
end

-- Map loads: drop every held game object WITHOUT touching it (no widget calls, not even to close the
-- panel) and stay idle until the new world has settled, as RSE-Fixes does. A controller, pause menu or
-- widget of the old world is freed with it, and calling into one crashes the game natively (a pcall
-- cannot catch it). Settings changed just before the load are saved first (file work only). After the
-- settle, the pause menu is found again as on first launch: its creation, or the search after Esc.
local function forgetWorld()
    pcall(saveDirty, true)
    cachedPC, nextPCScan = nil, 0
    pauseSeen, pauseKnown, pauseLookAt = {}, nil, 0
    MENU.pm, MENU.btn, MENU.btnName, MENU.shownLabel = nil, nil, nil, nil
    MENU.pending, MENU.wait = nil, 0
    PAD.seen = false
    panel.open, panel.frame, panel.ui, panel.rows, panel.buttons = false, nil, nil, {}, {}
    panel.mode, panel.padBtns, panel.order, panel.pm, panel.pc = nil, nil, nil, nil, nil
    panel.pending, panel.hintShown = nil, nil
    escCheck = nil
    idleUntil = os.clock() + 60                        -- the load-finished hook shortens this to SETTLE
end
if type(RegisterLoadMapPreHook) == "function" then
    pcall(RegisterLoadMapPreHook, function() forgetWorld() end)
end
if type(RegisterLoadMapPostHook) == "function" then
    pcall(RegisterLoadMapPostHook, function() idleUntil = os.clock() + SETTLE end)
end

log("loaded v" .. VERSION .. ", " .. #mods .. " configurable mods found.")

local tickErrors = 0
-- Main loop ON THE GAME THREAD. UE4SS runs LoopAsync callbacks on a separate thread without the lock
-- its game-thread side holds, so a LoopAsync mod's Lua can run on two OS threads at once (measured
-- 2026-09-23: ~1,480 overlaps in 150 jobs on stable and latest UE4SS alike; on the newer build it
-- corrupted a mod's Lua state under load). LoopInGameThreadWithDelay keeps all of it on one thread.
local function mainTick()
    if paused() then return end                        -- a map load is settling (see forgetWorld)
    local ok, err = pcall(panelTick)
    if not ok then
        tickErrors = tickErrors + 1
        if tickErrors <= 5 then log("tick error: " .. tostring(err)) end
    end
    pcall(menuTick)
    pcall(escTick)
    local okR, errR = pcall(requestTick)
    if not okR then log("open request error: " .. tostring(errR)) end
end
local okLoop = pcall(LoopInGameThreadWithDelay, 250, function()
    local ok, err = pcall(mainTick)
    if not ok then print("main loop error: " .. tostring(err) .. "\n") end
end)
if okLoop then print("[ModMenu] main loop on the game thread\n") end
if not okLoop then
    -- Older UE4SS without LoopInGameThreadWithDelay: the previous guarded LoopAsync route.
    -- Game-thread work only when the previous job has finished: queuing one every tick piles them up during
    -- a world-load stall and aborts UE4SS (Open All, 2026-09-17). The 5 s release covers a job UE4SS
    -- dropped, which would otherwise latch `queued` forever.
    local queued, queuedAt = false, 0
    LoopAsync(250, function()
        if queued and os.clock() - queuedAt > 5 then queued = false end
        if queued then return false end
        queued, queuedAt = true, os.clock()
        local sent = pcall(ExecuteInGameThread, function() queued = false; pcall(mainTick) end)
        if not sent then queued = false end
        return false
    end)
end
