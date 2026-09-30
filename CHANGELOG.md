# RSE-ModMenu changelog

RSE-ModMenu is Mod Menu 1.0.12 by Maxxfilth (MIT) with the fixes below. The mod id (`ModMenu`) and every shared variable name are unchanged, so every mod that supports Mod Menu works as before.

## 1.1.0 (RSE)
**Safety**
- **Config files are written safely.** A save goes to a temporary file first and replaces the real file only once it's complete. A crash, full disk or antivirus lock mid-save can no longer leave a mod's `config.txt` empty or half written. If renaming isn't allowed there, it writes in place as before.
- **Nested JSON settings are kept.** Saving a setting for a mod with a JSON config used to delete every nested object or array in that file. Values are now written back whole. Keys the mod doesn't list keep their place in a stable order.
- **A failed save is retried** every 5 seconds, up to 5 times, instead of being dropped. Before, a change was lost silently at the next restart.
- **Two copies no longer fight.** If the original `ModMenu` folder and `RSE-ModMenu` are both installed, the second one to load stays off and logs which folder to remove. Before, you got two MODS buttons, and both wrote the same config files.
- **Schema read errors are kept.** A `modmenu.json` over 256 KB now says so on the mod's page, instead of the error being overwritten by the `modmenu.txt` lookup.
- **Emoji and other characters above U+FFFF** in `modmenu.json` (`😀` surrogate pairs) now decode correctly.

**Performance**
- The pause-menu button no longer scans every object on the title screen. It asked for the player controller first, which ran `FindAllOf("PlayerController")` (about 50 ms) every 3 seconds while the title screen was open. Now it finds the pause menu first, which needs no scan, and uses the pause menu's own player.
- The local controller is cached when the game hands it over (`ClientRestart`), so the scan fallback rarely runs.
- One click hook instead of two, and it only reads the clicked button's name while one of Mod Menu's buttons exists.

**Cleanup**
- Removed the choice-carousel code that could never run (kept as a comment: it crashed the game, see 2026-09-25).
- Merged the two copies of the mod-loading code into one.
- Removed an unused variable pair from the main loop.

## Recommendations not done yet
1. **Cache the Mods folder listing.** `discover()` runs `IterateGameDirectories` and re-reads every `modmenu.json` and config file on each menu open and each open request. That's fine at today's mod counts, but the listing could be cached per session like the Game Pass fallback, which already is.
2. **`null` in JSON configs is lost on save.** The decoder turns `null` into "no key", so a `null` value disappears when the file is written back. It's rare in practice. The fix is a sentinel value for null.
3. **An empty JSON array `[]` is written back as `{}`.** Lua can't tell the two apart after decoding. Harmless for most readers.
4. **Game Pass fallback.** The first `dir` call via `io.popen` takes about 5.5 s and runs on the game thread the first time the menu opens. It could be started at load time instead.
5. **Localisation.** The menu's own strings are English only.
6. **Controller:** key pickers and text boxes still need a keyboard, as in 1.0.12.

## Testing
None of these changes have been run in game yet. The Lua files pass a syntax check only. Test at least:
- open and close from the pause menu, the menu key, and a controller
- change a setting and confirm the file updates
- change a setting while the config file is open in an editor
- install both the original ModMenu and RSE-ModMenu, and check that only one MODS button appears
