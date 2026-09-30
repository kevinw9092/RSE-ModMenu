# Mod Menu for RuneScape: Dragonwilds: guide for mod authors

Mod Menu adds one **MODS** button to the pause menu (Esc). Every installed mod that ships a
`modmenu.json` gets its own page there, drawn with the game's own checkboxes, sliders and buttons.

**Adding your mod takes one file. Your mod keeps working for players who don't install Mod Menu.**

- Works with UE4SS Lua mods that read a settings file (`config.txt`, a JSON file) or keep settings as
  plain values at the top of `main.lua`.
- Players change settings in game. Mod Menu writes them to your file.
- Optionally, about 15 lines of Lua let your mod pick up changes instantly, without a restart.

## 1. Add `modmenu.json` next to your `enabled.txt`

```
Mods/
  YourMod/
    enabled.txt
    modmenu.json      <- new
    config.txt
    Scripts/main.lua
```

The file may also be called **`modmenu.txt`**, with identical JSON inside. Mod Menu 1.0.4 and
later look for `modmenu.json` first and fall back to `modmenu.txt`. Use the `.txt` name if you
publish on CurseForge, whose "RSDragonwilds UE4SS Mods" category accepts only
`.txt .lua .dll .pak .utoc .ucas` and rejects an archive containing a `.json`.

The smallest useful file:

```json
{
  "name": "Your Mod",
  "settings": [
    { "key": "Enabled", "type": "toggle", "label": "Enabled", "default": true },
    { "key": "Multiplier", "type": "slider", "label": "Multiplier", "min": 1, "max": 10, "step": 0.5, "default": 2 }
  ]
}
```

With a `config.txt` like this, that's all you need:

```
Enabled = true
Multiplier = 2
```

Comments (`# ...` or `; ...`) and line endings in your file are kept. A setting that isn't in the
file yet is only added once the player changes it from the default.

## 2. Where your settings live: `config`

| Your mod stores settings in | Put this in `modmenu.json` |
|---|---|
| `config.txt` as `Key = value` lines (default) | nothing, or `"config": { "file": "config.txt" }` |
| another key/value file | `"config": { "file": "settings.ini" }` |
| a flat JSON object | `"config": { "file": "settings.json", "format": "json" }` |
| values at the top of `Scripts/main.lua` | `"config": { "format": "lua" }` |

**`"format": "lua"`** edits the first plain assignment to each key and leaves the rest of the script alone:

```lua
local MaxStack = 999          -- found: "MaxStack"
local ShowIcons = true        -- found: "ShowIcons"
local config = {
    Radius = 12.5,            -- found: "Radius" (a field in a table)
}
local OpenKey = Key.F8        -- NOT a plain value: shown as an error, never edited
```

Only numbers, `true`/`false` and quoted strings are edited, and only when they sit at the start
of a line with at most 8 spaces of indentation. Lua settings count as "applies after a restart"
unless you set `"restart": false` on them.

The file must be inside your mod folder.

## 3. Setting types

Every setting except `header` and `button` needs a `key` (letters, digits, `_ . -`).
All of them can have a `label` and a `tooltip`, shown at the bottom when the player hovers the row.

| type | fields | stored as |
|---|---|---|
| `toggle` | `default` true/false | `true` / `false` |
| `slider` | `min`, `max`, `step`, `default`, optional `decimals`, `suffix` (e.g. `"x"`) | number |
| `number` | same as `slider` (it is a slider) | number |
| `choice` | `options` (list of strings), `default` | the chosen string (shown as a button: each click steps to the next option) |
| `key` | `default` (UE4SS key name: `F8`, `HOME`, `PAGE_UP`, or `none`) | key name |
| `text` | `default`, optional `maxLength` (max 200) | string |
| `button` | `action` | not stored; sends an action (see live updates) |
| `header` | `label` | not stored; a section title |

Optional on any setting: `"restart": true` shows a `*` and "Applies after restarting the game".

Optional at the top level: `"id"` (defaults to your folder name), `"author"`, `"version"`,
`"description"`, `"schema": 1`.

A full example with every type is in `example/ModMenuExample/`.

## 4. Live updates (optional)

Mod Menu publishes values as UE4SS shared variables. Paste this into your `main.lua`, change the id,
and call `modMenuSync` from your own loop:

```lua
local MODMENU_ID = "YourMod"          -- your folder name, or the "id" in modmenu.json
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

-- in your main loop (use LoopInGameThreadWithDelay, see the example mod):
modMenuSync(function(get)
    local m = get("Multiplier"); if type(m) == "number" then Multiplier = m end
    local e = get("Enabled");    if type(e) == "boolean" then Enabled = e end
end)
```

Without Mod Menu installed, `rev` is nil and nothing happens.

| Shared variable | Value |
|---|---|
| `ModMenu.version` | Mod Menu's version string, while it is loaded |
| `ModMenu.<id>.<key>` | current value (boolean, number or string) |
| `ModMenu.<id>.rev` | number, goes up by 1 on every change to your mod's settings |
| `ModMenu.<id>.action` | `"<action>#<n>"` when a `button` is clicked (`n` changes every click) |

To open Mod Menu at your page from your own code (for example from your own pause-menu button):

```lua
ModRef:SetSharedVariable("ModMenu.request.open", "YourMod#" .. os.time())
```

## 5. Checking your file

Open the game, press Esc, click MODS, and pick your mod. Anything Mod Menu could not use is listed
in red at the top of your page, with the reason. A broken `modmenu.json` never affects other mods.
The UE4SS log shows `[ModMenu]` lines with any load problems.

## Compatibility promise

- `schema: 1` files keep working in every later Mod Menu version.
- Unknown fields are ignored, so you can add fields a newer Mod Menu understands without breaking
  older ones. A file that needs a newer Mod Menu says so on its page instead of failing.
- The shared variable names above won't change.

## Limits

- Pak and Blueprint-only mods can't read settings, so Mod Menu can't configure them.
- Up to 100 mods and 200 settings per mod. `modmenu.json` and config files up to 256 KB.
- Controllers (1.0.12): press A on MODS in the pause menu. The menu opens beside the pause list; press right to move
  into it, A selects or toggles, left/right changes a slider, B closes. Key pickers and text boxes need a keyboard.
- Co-op guests are untested.

License: MIT (see LICENSE).
