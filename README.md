# Forge Everything

A NeoForge 1.21.1 modpack. Not a kitchen sink — the entire kitchen, the sink, the cabinets, the fridge, and whatever's growing in the back of it.

**~498 mods** — ~500 client, ~457 server — plus three companion mods we wrote ourselves because the alternative was living with the problem: **Everything Ores**, **Everything Food**, and **Everything Bugs**. (They have placeholder assets currently. Dont worry, they wont stay like that)

---

## Just want to play?

Go to [Releases](../../releases/latest), download the client zip, import it into Prism Launcher. Done. You never have to read another word of this.

**This repo contains no mods.** It's ~493 tiny TOML files that know where mods *live*, plus five jars we're allowed to hand you directly. Cloning it gets you a very detailed shopping list and zero gameplay.

Everything past this point is for people who edit the pack. Turn back while you can.

---

## Contributor setup

### 1. Install packwiz

Grab a binary from [packwiz releases](https://github.com/packwiz/packwiz/releases), or build it yourself:

```bash
go install github.com/packwiz/packwiz@latest
```

Put it on your `PATH` and confirm it exists:

```bash
packwiz --version
```

### 2. Clone

```bash
git clone https://github.com/Rexilyent/forge-everything.git
cd forge-everything/packwiz
```

Every packwiz command runs from `packwiz/` — the directory with `pack.toml` in it. Running them from the repo root does nothing useful and will make you question your life choices for a solid ten minutes while you stare at an error; about not being able to find the file.

### 3. Set up a test instance

Point a Prism instance at your **local clone** so you can see your changes without pushing them to everyone first. Same setup as the released instance, except the pre-launch command uses a local path:

```
"$INST_JAVA" -jar "$INST_MC_DIR/packwiz-installer-bootstrap.jar" "C:/path/to/forge-everything/packwiz/pack.toml"
```

Keep a second instance pointed at the published URL. That one is what testers actually experience, and it will disagree with your local one at the worst possible moment.

---

## The one rule

> **Run `packwiz refresh` before every commit.**

`index.toml` stores a hash of every file in the pack. Commit without refreshing and the index confidently describes files that no longer exist in that form.

Here's the fun part: **it works perfectly on your machine.** You will never see it break. You'll push, close your laptop, and go make a sandwich while everyone else's launcher dies on a hash mismatch. Then someone pings you.

It takes one second. Just do it.

---

## Adding mods

### One at a time

```bash
cd packwiz

packwiz mr add <modrinth-slug>       # Modrinth
packwiz cf add <curseforge-slug>     # CurseForge
packwiz refresh
```

Commit, push, move on with your day.

**Use `mr add` when the mod exists on both.** Not a style preference — a CurseForge-sourced entry can't be exported to a `.mrpack` as a reference, because CurseForge CDN links aren't allowed in that format. The jar gets bundled into `overrides/` instead, which is redistribution, which several licenses in this pack explicitly forbid. Picking the wrong platform today is a legal problem later. See [Licensing](#licensing).

### CurseForge API is currently blocked

`packwiz cf add` talks to the CurseForge API, which returns **HTTP 403** from the primary dev machine. It's IP-level. A shiny new API key does not fix it. We tried. It did not work.

Do **not** sit there hammering retry — repeated rejected requests are the thing that makes these blocks longer. Use the worksheet workflow below and let it cool off.

### Removing and updating

```bash
packwiz remove <slug>
packwiz update <slug>          # one mod, responsibly
packwiz update --all           # everything, chaotically
packwiz refresh
```

At ~500 mods, one bad version bump can brick the launch for the entire team. `--all` is not a "eh, probably fine" command. Read the `git diff`. Actually read it.

---

## Bulk import

For importing a whole instance's worth of mods, or reconciling the pack against an instance that already works. Scripts live in the repo root, PowerShell 5.1 compatible, because that's what ships on Windows and we're not making anyone install a second PowerShell.

### The pipeline

```powershell
# 1. Hash every jar in an instance
.\Get-ModFolderInventory.ps1 -ModsFolder "<instance>\mods" -OutputCsv .\mod-folder-inventory.csv

# 2. Resolve those hashes against Modrinth and CurseForge, write .pw.toml entries
.\Resolve-InstanceByHash.ps1 `
    -InventoryCsv .\mod-folder-inventory.csv `
    -LinksFile .\links_to_mods.txt `
    -Apply -PackDir .\packwiz

# 3. For anything CurseForge refused to resolve (see above)
.\Build-CurseforgeEntries.ps1 `
    -ReportCsv .\hash-resolution-report.csv `
    -LinksFile .\links_to_mods.txt `
    -InstanceModsFolder "<instance>\mods"
#    ... fill in ProjectId + FileId in curseforge-worksheet.csv, then:
.\Build-CurseforgeEntries.ps1 -Apply -WorksheetCsv .\curseforge-worksheet.csv -PackDir .\packwiz

# 4. Set client/server sides from the working server
.\Set-ModSides.ps1 -ServerModsFolder "<server>\mods" -PackDir .\packwiz -Apply

# 5. Always. Every time. No exceptions.
cd packwiz; packwiz refresh
```

Steps 3 and 4 are dry-run by default. Nothing gets written without `-Apply`, so you can look before you leap.

### Why hashes and not URLs

The installed jar's SHA1 is ground truth. Resolve *that* against the platform APIs and you cannot end up with a wrong-version or wrong-filetype entry — the two things URL parsing gets wrong constantly, usually silently, usually right before a release.
Just, trust us on this one.

If a hash resolves, the entry is correct by construction. No vibes involved.

### The scripts

| Script | What it does |
|---|---|
| `PackConfig.ps1` | Shared config. Everything below dot-sources it. Resolution order: CLI parameter > process env > `secrets.local.env` > built-in default |
| `Get-ModFolderInventory.ps1` | Hashes a mods folder into a CSV |
| `Resolve-InstanceByHash.ps1` | Resolves SHA1s against Modrinth + CurseForge, writes `.pw.toml`. Also `-SelfTest`, `-TestCfKey`, `-CfStatus` |
| `Build-CurseforgeEntries.ps1` | Builds CurseForge entries with **zero API access**, from a worksheet you fill in by hand |
| `Set-ModSides.ps1` | Sets `side` from the server's mods folder |
| `Get-ModLicenses.ps1` | The licensing audit. See [Licensing](#licensing) |

### The CurseForge governor

`Resolve-InstanceByHash.ps1` polices itself, because we clearly can't be trusted to: a request ledger that persists across runs, a disk cache so re-runs cost nothing, and a circuit breaker that escalates (1h → 2h → 4h … 24h) every time CurseForge tells us no.

```powershell
.\Resolve-InstanceByHash.ps1 -CfStatus    # budget, cache size, cooldown, strikes
.\Resolve-InstanceByHash.ps1 -TestCfKey   # one live probe
```

If the breaker trips, **let it sit.** Clearing the cooldown to sneak in "just one more request" is precisely how a one-hour block becomes a one-day block. Go do something else. Touch grass. Play a game. Read a book before those are gone. Idk something but touching that.

### Secrets

Config and API keys go in `secrets.local.env` at the repo root. It's gitignored. Keep it that way!

```
INSTANCE_ROOT='C:\Users\<you>\AppData\Roaming\ModrinthApp\profiles\Forge Everything'
OUTPUT_DIR='${REPO_ROOT}\reports'
MODPACK_VERSION='v0.0.1-Alpha'
CF_API_KEY='$2a$10$...'
MODRINTH_TOKEN='...'
```

**Single-quote the values.** Not optional. A CurseForge key is bcrypt, which means it starts with `$2a$10$`, and PowerShell will cheerfully interpolate every one of those `$` sequences inside double quotes and hand the API a key made of nothing. It won't error. It'll just fail to authenticate forever while you stare at a 401 wondering what you did.

`${VAR}` expansion works, and is deliberately switched off for any key ending in `_KEY`, `_TOKEN`, `_SECRET` or `_PASSWORD` — for exactly the reason above.

---

## Sides

`side` decides who actually receives a mod. The server's mods folder is the source of truth.

Current split: **~500 client / 457 server.**

`Set-ModSides.ps1` works this out for you, mostly. It reads one signal — is this jar on the server or not — and there are three possible answers, so you can see where this is going:

| Jar is... | Script says | Right? |
|---|---|---|
| on the server | `both` | Only if the client loads it too |
| not on the server | `client` | Yes |
| on the server and **never loaded by a client** | `both` | **Nope. Should be `server`** |

There's no client-side evidence a script could use to spot the difference, so **`server` is permanently a human call.** If the script proposes `both` for something a client never touches — login handlers, server utilities, anti-cheat — revert it and set `side = "server"` yourself. `EvoLoginTimeout` is the current offender, and it will keep proposing the same change every single run. It's not learning. (Because why would it, it's not AI; it's a script that we clearly need to work on) Just say no again.

---

## Loose jars

Five jars ship straight out of this repo instead of as metadata:

| Jar | License | Why |
|---|---|---|
| `everythingores.jar` | MIT | Ours. Not published anywhere. |
| `everythingbugs.jar` | All Rights Reserved | Ours. Not published anywhere. |
| `everythingfood-0.0.1.jar` | _[TEAM: undeclared]_ | Ours. Not published anywhere. |
| `ars_elemental-*.jar` | LGPL-3.0 | Author turned off CurseForge third-party distribution |
| `chisels-and-bits-*.jar` | MIT | Same deal |

Loose jars have **no `side` field** and always land on both client and server.
 
### Our license, such as it is
 
**Assume everything of ours is All Rights Reserved right now.** That's the safe default until we say otherwise in writing.
 
Where it's going:
 
- **Code will almost certainly go open source.** Why wouldn't it. Everything Ores adds a pile of items and unifies tags; Everything Bugs patches Voltaic and friends in roughly the way AllTheLeaks patches things. None of that is a trade secret. It's a modpack.
- **Assets never will.** Every logo, name, wordmark, texture, image and piece of branding is off limits, permanently, no exceptions, don't ask. Some of these took days. Some took weeks. Aseprite is just where the pixels land — what's in them is years of art classes, Photoshop and Illustrator, an unreasonable quantity of YouTube tutorials, and a lot of art nobody ever saw. None of that came free either. The code is a favour we're happy to do. The art is not on the table.
Yes, we are aware that a pack shipping three first-party jars with three different license declarations — MIT, All Rights Reserved, and whatever Everything Food is doing — is *precisely* the thing we wrote 500 rows of `LICENSE.md` gently roasting other authors for. We contain multitudes. It's getting fixed; or so we hope.

**When updating one:**

1. **Delete the old jar first.** Two versions of the same mod in `mods/` means packwiz ships both, and NeoForge hard-fails on the duplicate mod ID. Instantly. For everyone.
2. Copy in the new jar.
3. `packwiz refresh` — the index stores the jar's hash, and a stale hash breaks every client. Yes, this is the same rule as before. It's the rule.
4. Commit and push.

See `THIRD-PARTY.md` for Ars Elemental's LGPL attribution and Chisels & Bits' MIT notice. (Seriously.... Make the Third-Party.md already...)

---

## Licensing

The pack ships a `LICENSE.md` recording every mod's license and where we stand on permission for it. This is not us being precious — Modrinth now requires proof of permission for all external content before a modpack can even be submitted. This *is* the proof. (If we ever get permission from some mod authors to put the pack on modrinth - Curseforge only mod authors need to be asked)

```powershell
.\Get-ModLicenses.ps1 -VerifyModrinth -DumpLicenseFiles
```

It reads three independent sources per mod — the LICENSE file bundled in the jar, the Modrinth listing matched by SHA-1, and the `license` field in `META-INF/neoforge.mods.toml` — and when they disagree it writes down that they disagree instead of quietly picking a winner.

| File | What it is | Who owns it |
|---|---|---|
| `reports/mod-licenses.csv` | Raw scanner output, one row per mod | Generated |
| `reports/license-texts/` | License files pulled verbatim out of jars | Generated |
| `reports/permissions.csv` | Per-mod permission verdicts and evidence | **You. By hand. Never overwritten** |
| `LICENSE.md` | The published document | Generated from all three |

Two constraints that genuinely limit how this pack can ship:

- **Manifest distribution is the whole reason we're compliant.** A bunch of these licenses permit modpack use *only by reference*. Because this repo publishes `.pw.toml` files instead of jars, players download from the author's own CDN and we redistribute nothing. Bundle the jars — a `.mrpack` with `overrides/`, a zip of `mods/` — and that protection evaporates, whether or not anyone's making money.
- **Non-commercial clauses are a separate problem from redistribution clauses.** Several mods here forbid commercial advantage, and Modrinth monetises projects by default. So publishing there is a decision someone has to make on purpose, not something to find out about later.

---

## Branches

The `pack.toml` URL has the branch name in it, which makes branches release channels:

| Branch | Who's pointed at it |
|---|---|
| `main` | Testers. Blessed builds only. |
| `dev` | Us. Actively on fire. |

Work on `dev`, merge to `main` when a build is worth inflicting on other people, bump `version` in `pack.toml` on every merge.

---

## Repo layout

```
packwiz/
├── pack.toml            # entry point: versions, index hash
├── index.toml           # hash of every file below — generated, never hand-edit
├── mods/                # ~493 .pw.toml + 5 loose jars
├── config/              # mod configs — these matter, see below
├── resourcepacks/
├── shaderpacks/
└── .packwizignore

reports/                 # licensing audit output
├── mod-licenses.csv
├── license-texts/
└── permissions.csv      # hand-maintained

*.ps1                    # tooling (see Bulk import)
LICENSE.md               # generated — do not hand-edit
THIRD-PARTY.md           # notices for the loose jars
curseforge-worksheet.csv # CurseForge project/file IDs, hand-maintained
secrets.local.env        # gitignored
```

### Configs are not optional

Several of these encode fixes that took a genuinely unreasonable amount of time to track down. Ship without them and you get to rediscover every bug personally:

- **Ballistix** — `should_cache_explosions = false`. Without it: ~1.25 GB retained at startup, doing nothing.
- **Quark** — `AutomaticRecipeUnlockModule` disabled. Without it: a 35–38 second stall on join.
- **InControl** — 315 spawn rules. Without them: 40–60% more mob AI overhead.
- **forgeeverything_datapack** (Paxi) — ore worldgen suppression. Without it: every duplicate ore generates again and Everything Ores' entire reason for existing becomes invisible. (We only removed silver ore from like 1 one mod atm for testing purposes)

Adding a mod that needs config to behave itself? Commit the config in the same change. Not the next one.

---

## Troubleshooting

**Hash mismatch at launch — on somebody else's machine**
Someone committed without `packwiz refresh`. It's always this. Refresh, commit, push, apologize.

**"Duplicate mod ID" crash after a loose-jar update**
Two versions of the same jar are sitting in `packwiz/mods/`. Delete the old one, `packwiz refresh`, push.

**A mod just... doesn't install**
Check `side`. A mod marked `client` will never reach the server and vice versa. Re-derive with `Set-ModSides.ps1` rather than editing `.pw.toml` by hand and hoping. (If that didn't fix your issue then by all means hand-edit the thing and pray you didnt mistype something.)

**A loose jar isn't being published**
`.packwizignore` lets a fixed list of five through and skips everything else. New loose jar means a new entry in that list.

**`packwiz cf add` returns 403**
Expected. See above. Use `Build-CurseforgeEntries.ps1` and the worksheet, and resist the urge to retry — that's what makes it worse.

**Server kicks clients at join / keep-alive timeout**
Known fight between AllTheLeaks ingredient locking and JEI rebuilding its recipe index on the render thread. Tracked in the Obsidian vault under `Known_Issues_Log.md`. The real fix is finishing Everything Ores' unification so the duplicate ingredient stacks stop existing in the first place.

**Client dies with commit-limit / allocation errors on Windows**
Two ZGC heaps with `AlwaysPreTouch` and no uncommit will burn through the Windows commit limit long before you run out of actual RAM. Client heap at 16 GB, equal `Xms`/`Xmx`, and watch *total committed heap across every JVM* — not per-process usage, which will look completely fine while everything falls over.
