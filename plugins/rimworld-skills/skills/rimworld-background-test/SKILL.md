---
name: rimworld-background-test
description: Verify a RimWorld 1.7 mod in the real game by running a separate game instance that shows no window on the user's screen and plays no sound. Loads a copy of a save (or a quicktest map), runs a step script (tick, select a pawn, open an inspect tab, change fields, measure frame time, take screenshots) and collects the results. Use for requests such as "test it in the game", "capture it in the real game", "check it in game", "measure the frame time" (in Korean, e.g. "게임 켜서 테스트해줘", "실제 게임에서 캡처해줘", "게임 안에서 확인해줘", "프레임 측정해줘"). Do not launch the game with this skill unless the user asked for the game to be run.
---

# RimWorld background game test (hidden window, muted)

The user's save data folder (LocalLow) is never touched. The runner copies the Config into a temporary
save data folder, sets every volume in that copy to 0, and starts the game with `-NoWindow`: the GLFW
window is created but never made visible, rendering continues, so screenshots work. The test driver mod
(`driver/`) sits in the Mods folder only for the length of the run, executes the step script line by
line and then quits the game.

## Before you start

- **Only launch the game when the user asks for it.** Otherwise stop at building and unit tests.
- **The runner refuses to start while the user's game is running**, because both instances would write
  the same `Logs\Player.log`. If the user wants to go ahead anyway, pass `-AllowWhileRunning`; the logs
  then mix and the runner does not restore Player.log.
- **The mod under test must be in the Mods folder or the Workshop.** If it is off in the user's
  ModsConfig, switch it on for the test instance only with `-Enable <packageId>`.
- **Do not rebuild a DLL that the user's running game has loaded.** Replacing it mid-game breaks the
  same way as hot-swapping a jar.

## Steps

1. **Write a step script.** Keep it as a text file in the session scratchpad (format below).
2. **Run it.** With the 226-mod setup, boot and save load take about a minute and a day of ticks (60,000)
   about another 40-60 seconds. Runs can exceed two minutes, so run in the background.

   The runner is `scripts\run-test.ps1` in this skill's folder: the base directory shown when the skill
   loads (inside the plugin cache when installed as a plugin). Use that absolute path:

   ```powershell
   & "<skill base directory>\scripts\run-test.ps1" -Script <script path> -Enable <packageId>
   ```

   Options:
   - `-Save <name>`: a save in the user's Saves folder, without `.rws`. Default: the newest save that is
     not an autosave or a BadEvent save. It is copied as `test.rws`, so the script loads it with `load test`.
   - `-QuickTest`: start on a quicktest map instead of a save. The script then starts with `waitmap`
     instead of `load`.
   - `-Enable` / `-Disable`: switch mods on or off in the test instance's ModsConfig only.
   - `-Headless`: no rendering at all. Lighter, but `shot` fails.
   - `-Out <folder>`: result folder. Default: `%TEMP%\rimworld-background-test\out-<timestamp>`.
   - `-KeepData`: keep the temporary save data folder (to inspect the loaded save or settings).
3. **Read the results.** The runner prints these at the end:
   - `run-info.txt`: save used, launch arguments, exit code, duration, and the `audio:` line.
     - It must say `audio: silent` or `no audio session`.
     - `AUDIBLE` means muting failed; fix that before anything else.
   - `driver-log.txt`: a log line per step and a final `RESULT: OK` or `RESULT: FAILED`. A failure
     includes the exception stack.
   - `stdout.txt`: the game log. Search it for the tested mod's name or namespace to pick out its own
     errors. This PC has some errors that are always there (Storyteller translation injection
     TypeLoadException, WorkTab.Controller InvalidProgramException, NewRatkin "Null key"); they are not
     caused by the tested mod.
   - `*.png`: screenshots at the user's Prefs resolution (2560x1369, UI scale 1.25). Crop the part you
     need with `scripts/crop.py`, look at it with Read, and send it to the user with SendUserFile.
   - The script's exit code is 0 only when the driver log ends in `RESULT: OK`.
4. **Check the cleanup.** The runner does this in `finally`; check it yourself if a run was cut short:
   - `Mods\zz-BackgroundTestDriver` is removed.
   - The user's `Player.log` is restored to its previous content.
   - The temporary data folder is deleted.
   - The lock folder `%TEMP%\rimworld-background-test\run.lock` is removed. If it is left behind, the
     next run refuses to start.

## Step script

One command per line; lines starting with `#` are comments. Each command may span several frames. A
failing step writes `RESULT: FAILED` and quits the game. The game also quits at the end of the script
without `quit`, and the driver gives up after 30 minutes.

| Command | What it does |
| --- | --- |
| `load test` | Loads the save from the main menu, waits until the map is ready, then pauses |
| `waitmap` | Waits until the map is ready (for quicktest starts) |
| `closewindows` | Closes every open window except the inspect pane (Moody, minimap, first-run popups...) |
| `tick <n>` | Runs n ticks while paused, 0.4 s per frame, and logs the TPS |
| `speed <0-4>` | Sets the game speed (0 = paused). Combine with `waitsec` to run in real time |
| `wait <frames>` / `waitsec <seconds>` | Waits. After changing UI state, `wait 20` lets it redraw |
| `select [colonist] [index or part of name]` | Selects a colonist and moves the camera. Without an argument: the colonist with the lowest id |
| `opentab <full ITab type name>` | Opens that inspect tab for the selection; fails if the tab is not visible for it |
| `measure <frames> <label>` | Skips 10 frames, then logs mean, p95 and max frame-to-frame time |
| `shot <file.png>` | Captures the whole screen and waits until the file size is stable |
| `settab <ITab type> <member.path> <value>` | Sets a field or property (private ones too) on the shared tab instance |
| `setstatic <type> <member.path> <value>` | Follows the path from a static member and sets the last one, e.g. `Settings.SplitWalking false` |
| `call <type> <static method>` | Calls a parameterless static method and logs the return value |
| `log <text>` | Writes a marker to the log |
| `quit` | Quits |

Values are converted to the member's type: bool, integer, float, string; enums by name or number.
`+=N` adds N to an integer (for example to bump a settings version so a view rebuilds).

## Example: capture an inspect tab and measure frame time

The flow used to verify the Daily Work Stats mod (`jungooji.dailyworkstats`) on 2026-11-13:

```text
load test
closewindows
# run a bit more than a day so there are records
tick 78000
closewindows
select colonist
measure 300 tab closed
opentab DailyWorkStats.UI.ITab_Pawn_DailyStats
measure 300 tab open
shot today.png
# private field pick: 0 today, 1 yesterday
settab DailyWorkStats.UI.ITab_Pawn_DailyStats pick 1
wait 20
shot yesterday.png
setstatic DailyWorkStats.DailyWorkStatsMod Settings.SplitWalking false
setstatic DailyWorkStats.DailyWorkStatsMod Settings.Version +=1
wait 20
shot nosplit.png
```

Measured that day: 14 s from boot to map ready, 42 s for 78,000 ticks, and 6.06 ms frame time with the
tab both closed and open. Inspect tabs open just above the inspect pane in the bottom left, so cropping
around x 0-790, y 0-840 of the capture contains the whole tab.

## Pitfalls

- **First-run popups:** a new save data folder can show first-run popups such as the Achtung welcome
  window. Copying the Config prevents most of them, but put `closewindows` before a capture anyway.
- **FastLoader cache:** the user's Config holds a FastLoader texture cache of about 900 MB. FastLoader is
  not used on 1.7, so the runner skips it.
- **The `-mod=` switch:** it accepts only mods in the local Mods folder and ignores Workshop Harmony, so
  the runner edits a copy of ModsConfig instead.
- **Windows per-app mute:** Windows remembers per-app volume by exe path, so muting there would also
  silence the user's own game. It is not used; volumes are zeroed only in the test instance's Prefs
  copy and by the driver.
- **Nothing is visible on screen:** a `-NoWindow` instance cannot be watched; judge it only by the logs
  and screenshots.
- **Changing the driver or the runner:** edit the clone of the `rimworld-skills` repository, not the
  installed copy in the plugin cache, which is replaced on every plugin update. Rebuild the driver with
  `dotnet build -c Release` in `driver/Source` (output: `driver/1.7/Assemblies`, delete `obj` and `bin`
  afterwards), bump `version` in the plugin's `plugin.json`, commit, push, then update the plugin.
- **Related notes:** the headless multi-instance proof of concept and its orchestrator
  (`source/rimworld-refs/tools/HeadlessOrchestrator`) are described in the memory note
  `rimworld-headless-multi-instance`. This skill packages only the single-instance, hidden-render,
  muted path from that work.
