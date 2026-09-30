-- Mod Menu Example: a mod that reads config.txt as usual and, when Mod Menu is installed, picks up
-- changes live. Copy this folder, rename it, and replace the settings with your own.
local TAG = "[ModMenuExample] "
local function log(msg) print(TAG .. tostring(msg) .. "\n") end

local cfg = { Rate = 1.0, Count = 5, Enabled = true, Mode = "Detailed", Hotkey = "HOME", Title = "Hello" }

-- 1. Read config.txt (this is all a mod needs for Mod Menu to work after a restart) ----------------
local function modRoot()
    local src = (debug.getinfo(1, "S").source or ""):gsub("^@", "")
    return src:match("^(.*)[/\\]Scripts[/\\][^/\\]*$")
end
local function loadConfig()
    local root = modRoot()
    local f = root and io.open(root .. "\\config.txt", "r")
    if not f then return end
    for line in f:lines() do
        local k, v = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
        if k and cfg[k] ~= nil then
            v = v:gsub("%s+[#;].*$", "")
            if type(cfg[k]) == "boolean" then cfg[k] = v:lower() == "true"
            elseif type(cfg[k]) == "number" then cfg[k] = tonumber(v) or cfg[k]
            else cfg[k] = v end
        end
    end
    f:close()
end
loadConfig()

-- 2. Optional: live updates from Mod Menu -----------------------------------------------------------
local MODMENU_ID = "ModMenuExample"
local mmRev = nil
local function modMenuSync(apply)
    local ok, rev = pcall(function() return ModRef:GetSharedVariable("ModMenu." .. MODMENU_ID .. ".rev") end)
    if not ok or type(rev) ~= "number" or rev == mmRev then return end
    mmRev = rev
    apply(function(key)
        local okV, v = pcall(function() return ModRef:GetSharedVariable("ModMenu." .. MODMENU_ID .. "." .. key) end)
        if okV then return v end
    end)
end

local lastAction = nil
-- Run your loop on the GAME THREAD. UE4SS runs LoopAsync callbacks on another thread without a lock,
-- so if your mod also does game-thread work (ExecuteInGameThread, UI, hooks) its Lua can run on two
-- threads at once and corrupt itself. LoopInGameThreadWithDelay avoids that entirely.
local function loop()
    modMenuSync(function(get)
        for k, old in pairs(cfg) do
            local v = get(k)
            if v ~= nil and type(v) == type(old) and k ~= "Hotkey" then cfg[k] = v end   -- Hotkey needs a restart
        end
        log(string.format("settings now: Rate=%s Count=%s Enabled=%s Mode=%s Title=%s",
            tostring(cfg.Rate), tostring(cfg.Count), tostring(cfg.Enabled), cfg.Mode, cfg.Title))
    end)
    -- 3. Optional: buttons send actions
    local ok, a = pcall(function() return ModRef:GetSharedVariable("ModMenu." .. MODMENU_ID .. ".action") end)
    if ok and a ~= nil and a ~= lastAction then
        lastAction = a
        if tostring(a):match("^hello#") then log("Hello from the SAY HELLO button! Title is: " .. cfg.Title) end
    end
end
if not pcall(LoopInGameThreadWithDelay, 500, function() pcall(loop) end) then
    LoopAsync(500, function() pcall(loop); return false end)   -- very old UE4SS
end

local key = Key[(cfg.Hotkey or ""):upper()]
if key then RegisterKeyBind(key, function() log("Hotkey pressed. Enabled=" .. tostring(cfg.Enabled)) end) end

log("loaded. Rate=" .. tostring(cfg.Rate) .. ", Mod Menu version: " .. tostring((function()
    local ok, v = pcall(function() return ModRef:GetSharedVariable("ModMenu.version") end)
    return ok and v or "not installed (or loads after this mod)"
end)()))
