# rimworld-skills

Claude Code skills for RimWorld 1.7 (Waylith) mod development on Windows.

| Skill | What it does |
| --- | --- |
| [`rimworld-background-test`](skills/rimworld-background-test/SKILL.md) | Runs a step script (load a save, tick, select a pawn, open an inspect tab, change fields, measure frame time, take screenshots) in a separate game instance that has no visible window and no sound, then cleans up. |

## Install

Each folder under `skills/` is one skill. Link it into the user skills folder so edits here take effect
directly:

```powershell
New-Item -ItemType Junction -Path "$env:USERPROFILE\.claude\skills\rimworld-background-test" -Target "<clone>\skills\rimworld-background-test"
```

## rimworld-background-test

- `scripts/run-test.ps1`: the runner. Copies the user's Config into a temporary save data folder,
  sets every volume to 0 in that copy, adds the test driver to Mods for the length of the run,
  launches `RimWorld.exe -NoWindow`, measures the process's audio peak while it runs, and restores
  everything afterwards. The user's own Config, Prefs and saves are never written.
- `driver/`: the test driver mod (`jungooji.backgroundtestdriver`). It acts only when the game is
  launched with `-tdscript=PATH` and a `-savedatafolder` outside the default folder. The built DLL
  is committed so the skill works without a build; rebuild with
  `dotnet build driver/Source -c Release` after changing it.
- `scripts/crop.py`: crops a screenshot (`uv run -q --no-project --with pillow python -I crop.py ...`).

Paths to the game (`C:\Program Files (x86)\Steam\steamapps\common\RimWorld`) and to RimWorld's save
data folder are fixed in the runner and the driver project.
