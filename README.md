# rimworld-skills

A Claude Code plugin marketplace with skills for RimWorld 1.7 (Waylith) mod development on Windows.

| Plugin | Skill | What it does |
| --- | --- | --- |
| `rimworld-skills` | [`rimworld-background-test`](plugins/rimworld-skills/skills/rimworld-background-test/SKILL.md) | Runs a step script (load a save, tick, select a pawn, open an inspect tab, change fields, measure frame time, take screenshots) in a separate game instance that has no visible window and no sound, then cleans up. |

## Install

In Claude Code:

```
/plugin marketplace add zzzz465/rimworld-skills
/plugin install rimworld-skills@rimworld-skills
```

Or from a shell:

```bash
claude plugin marketplace add zzzz465/rimworld-skills
claude plugin install rimworld-skills@rimworld-skills
```

The repository is private, so the machine needs git access to it (for example `gh auth login`).
Start a new session after installing; the skill is then listed as `rimworld-skills:rimworld-background-test`.

To pick up new versions:

```bash
claude plugin marketplace update rimworld-skills
claude plugin update rimworld-skills@rimworld-skills
```

### Developing from a local clone

Register the clone as a directory marketplace instead, so it installs from your working copy:

```bash
claude plugin marketplace add <path to clone>
claude plugin install rimworld-skills@rimworld-skills
```

The installed copy lives in the plugin cache. After editing the clone, bump `version` in
`plugins/rimworld-skills/.claude-plugin/plugin.json` and run the two update commands above.

## Layout

```
.claude-plugin/marketplace.json              marketplace: lists the plugins in this repository
plugins/rimworld-skills/
  .claude-plugin/plugin.json                 plugin manifest
  skills/rimworld-background-test/
    SKILL.md                                 instructions Claude follows
    scripts/run-test.ps1                     runner: isolated, hidden, muted game instance
    scripts/crop.py                          crops screenshots
    driver/                                  test driver mod (jungooji.backgroundtestdriver), built DLL included
```

## rimworld-background-test

- `scripts/run-test.ps1` copies the user's Config into a temporary save data folder, sets every volume
  to 0 in that copy, adds the test driver to Mods for the length of the run, launches
  `RimWorld.exe -NoWindow`, measures the process's audio peak while it runs, and restores everything
  afterwards. The user's own Config, Prefs and saves are never written.
- `driver/` acts only when the game is launched with `-tdscript=PATH` and a `-savedatafolder` outside
  the default folder. Rebuild with `dotnet build driver/Source -c Release` after changing it.
- `scripts/crop.py` crops a screenshot (`uv run -q --no-project --with pillow python -I crop.py ...`).

Requirements: Windows, RimWorld 1.7 at `C:\Program Files (x86)\Steam\steamapps\common\RimWorld`
(fixed in the runner and the driver project), Windows PowerShell 5.1, and `uv` for cropping.
