# Contributing to Forge Everything

The README covers **how** to work on the pack — packwiz, the scripts, the sides table, the licensing audit. Read that first; it's the manual.

This file covers **what we'll actually merge.** It's shorter and considerably more opinionated.

---

## Before you open anything

- Work on `dev`. `main` is for builds we've decided to inflict on testers.
- Run `packwiz refresh` before every commit. Yes, still. It's still the rule.
- One PR, one concern. A branch that adds three mods, rewrites a script, and "also fixed some formatting" is a branch nobody can review and nobody can revert cleanly.
- If it needs a config to behave, the config ships in the same PR. Not the next one. (Don't be Rexi :P)

---

## AI: read this part twice

We're not anti-AI. We're anti-*slop*. There's a difference, and the line is not blurry.

### Assets: absolutely not! Ever!

**No AI-generated assets will be merged into this pack. Not one!**

That means textures, models, item sprites, block sprites, GUI elements, logos, wordmarks, banners, icons, quest art, splash images, promotional art, sound effects, music, and anything else a player can see or hear. AI-generated, AI-upscaled, AI-"cleaned up," AI-inpainted, run through a generator and then hand-edited so it's "basically original now" — all of it. No.

This isn't a debate we're having in a PR thread. The README says it plainly: some artwork took days, some took weeks, and behind them are years of art classes, an unreasonable quantity of tutorials, and a great deal of art nobody ever saw. The art is not on the table, and it's not being replaced by something a model regurgitated in nine seconds from work other artists didn't consent to being fed into it.

If your PR contains generated assets, it gets closed. Not reviewed, not negotiated, closed. If you don't have art skills, that's completely fine — contribute code, configs, quests, testing, documentation, or bug reports. Or ask and we'll find someone. There is a *lot* to do here that isn't drawing.

**Placeholder assets are the one narrow exception**, and only ours, and only the ugly programmer-art kind. A magenta-and-black checker is a placeholder. A generated texture is not a placeholder, it's the problem wearing a hat.

### Code: allowed, conditionally, and the conditions are real

You can use AI to help write code for this project. We do. Pretending otherwise would be silly.

What you **cannot** do is vibecode.

If you prompted a model, skimmed the output, watched it compile, and opened a PR — that's not a contribution, that's outsourcing your homework to us. We are the ones who find out it was broken. Usually at 2 AM. (Or 10pm because thats some people's 2am) Usually because forty people's launchers just died.

The bar for AI-assisted code is exactly the bar for hand-written code, which is:

**1. You understand every line you're submitting.**
If we ask why a mixin uses `synchronized (EntityRenderers.class)` instead of locking on the mixin class, you need an answer. Not a vibe. An answer. If you can't explain it, you can't defend it, and you definitely can't fix it when it breaks six months from now.

**2. You tested it. Genuinely tested it. For a long time.**
See the next section, because this is the part people skip.

**3. It isn't someone else's code wearing a disguise.**
Models reproduce their training data. Sometimes verbatim, sometimes near enough that the license still applies. If a chunk of your PR is functionally a paste of another mod's implementation, we need to know where it came from and what license it's under — *before* it lands, not after somebody recognises it.

If you deliberately took code from another project: say so, check the license, credit it in the file header, and add it to `THIRD-PARTY.md`. Most authors are fine with it when you ask. Almost none are fine with finding out by accident.

We maintain a 500-row `LICENSE.md` and wrote a scanner to generate it. We are not about to be careless with our own attribution. That would be embarrassing.

**4. Disclose it.**
If AI wrote a meaningful portion of a PR, put a line in the description saying so and saying what you did to verify it. This isn't a scarlet letter — it tells the reviewer where to look harder. Hiding it and getting caught is the thing that ends the conversation.

---

## What "thoroughly tested" actually means

Not "it compiled." Not "it launched once." Not "worked on my world."

Depending on what you touched, testing this pack is measured in **hours at minimum, and for anything structural, weeks or months.** That's not hyperbole and it's not gatekeeping — it's just what a ~500 mod pack costs. Bugs here don't show up on launch. They show up on hour six, in a chunk nobody visited, on somebody else's hardware.

Before you say it's tested:

- **Run it in the actual pack.** Not a dev workspace with four mods in it. The whole thing. The bugs are all in the interactions.
- **Client *and* dedicated server.** Singleplayer and LAN are not a server test. Half of what breaks here breaks at join.
- **Fresh world and existing world.** Anything touching worldgen, tags, recipes, or registries can behave completely differently on a world that already has chunks.
- **Read the log.** Not just for crashes — for *new* warnings that weren't there before. "No crash" is a low bar and it lies to you constantly.
- **Play it.** Multiple sessions. Actually progress through something. A world you loaded and stood in for ninety seconds is untested.
- **Profile if you touched a hot path.** Anything on the tick loop or render thread gets spark on it before it gets a PR.
- **Mixins get tested against the real conflicting mod versions.** A mixin that works because the target didn't load is not a working mixin.
- **Tag and recipe changes get a ProbeJS dump comparison.** "The recipe shows up in JEI" is not the same as "no unification conflicts."

If you touched Everything Ores' unification, worldgen suppression, or anything with ingredient locking near it: budget weeks. We've been in that particular pit for a while now and it is deeper than it looks.

### Prove your fix didn't punch a hole in the pipes

This is the part that separates "it stopped crashing" from "it stopped crashing *for now*."

Plenty of fixes work by holding onto something. You cache a lookup so it stops recomputing. You keep a reference so it stops being null. You register a listener so the event stops getting missed. Every one of those is a perfectly good fix and every one of them is also, if you got it slightly wrong, a memory leak with a very polite bedside manner. It won't crash your test session. It'll crash somebody's server on hour nine.

So: **if your change touches caching, references, listeners, registries, chunk data, or anything that lives longer than one tick, you bring memory evidence with the PR.** Not vibes. Artifacts.

**Spark heap summary — the cheap first look.**
`/spark heapsummary` gives you a class histogram without the pain of a full dump. Run it with a GC first so you're looking at what's actually retained rather than garbage that hasn't been swept yet. On its own a single summary tells you very little. **Two summaries do.** Take one after join and settle, take another after several hours of the same world under the same conditions, and compare. If a class you touched has climbed while everything else is flat, that's more than likely your answer and you didn't even need MAT.

**Spark heap dump — when the summary points at something.**
`/spark heapdump` writes a `.hprof`. Open it in Eclipse MAT and go straight to the dominator tree and the path-to-GC-roots for whatever's growing. The question is never "how much memory is this using," it's **"what is still holding a reference to this and why."** Shallow heap is a distraction; retained heap and the GC root path are the whole investigation.

**Take the summary after a GC, and mean it.** We have a cautionary tale in-house: a heap that appeared to be sitting on roughly 38,780 retained `ChunkAccess` objects turned out to be a measurement artifact of the old ZGC configuration — garbage that had been collected but not swept out of the picture, counted as if it were live. It read like a serious chunk-retention leak for a while. It wasn't one. If you dump without forcing collection first, you will invent a leak and then spend a weekend hunting something that was never there.

So don't take a number from someone else's session, someone else's collector, or someone else's config as your baseline. **Establish the floor yourself, on the current setup, before and after your change.** The delta is the evidence. The absolute number is nearly meaningless.

**GC logs — the leak detector you already have running.**
The shipped JVM args write `./logs/gc.log`. The thing to read is not pause times, it's **the heap occupancy floor after each old-generation collection.** A healthy pack sawtooths and comes back down to roughly the same level every time. A leak sawtooths and the bottom of each tooth sits a little higher than the last. Draw that line across a four-hour session and you'll know before you ever open a dump.

Also worth flagging in the log: full GCs appearing where there weren't any, `to-space exhausted`, and humongous allocation churn.

One gotcha — the shipped java args rotates at three files of 10 MB, so a long leak hunt will quietly eat its own early evidence. Bump `filecount` for the session, then put it back. `-Xlog:gc*:file=./logs/gc.log:time,uptime:filecount=3,filesize=10m`

**hs_err_pid*.log — when it wasn't Java's fault.**
If the JVM dies with a native fault it drops an `hs_err_pid<n>.log` in the instance directory. This is not the same thing as a crash report and it is not the same thing as an OOM. Read the failing thread and the *problematic frame* — if that frame is a native library rather than Java code, you're looking at a driver or a native-allocating mod, not your heap. Include the file. The memory map and native allocation sections at the bottom are frequently the whole story.

Note that `-XX:+HeapDumpOnOutOfMemoryError` only fires for **Java heap** exhaustion. Direct buffers, metaspace, native allocations, and the machine running out of commit will all kill the process without producing a heap dump at all. If the JVM vanished and left no `.hprof` and no `hs_err`, that absence is itself the diagnostic.

**Windows event log and WER — for the crashes that left no note.**
When it dies hard enough that the JVM can't write anything, Windows still saw it. Event Viewer → Windows Logs → Application, look for the Application Error entry and its faulting module. Separately, `Resource-Exhaustion-Detector` events are what a commit-limit death looks like from the OS side, and they are worth checking any time the whole machine got sluggish rather than just the game.

For a native fault worth actually debugging, configure `LocalDumps` under the Windows Error Reporting registry key so WER writes a minidump to `%LOCALAPPDATA%\CrashDumps` (or whatever folder you choose) instead of silently discarding it. If you're chasing a repeatable graphics-driver crash, that minidump is the only thing that identifies the real faulting frame.

**And watch total system commit, not per-process memory.** The README's last troubleshooting entry exists because we learned this the expensive way: per-process numbers can look completely healthy while the machine is going down. If your testing involves multiple JVMs, that's the number that matters.

**If development was crashy, keep the wreckage.**
If you spent a week getting there and generated a pile of `hs_err` logs, GC logs, minidumps and heap dumps along the way — don't tidy them up before opening the PR. Bring them. "Here's what it was doing before, here's what it's doing now, here are the dumps from both" is the single most reviewable thing you can hand us, and it's the difference between a merge this week and a merge whenever somebody finds the time to reproduce your problem from scratch.

**We will not merge work that hasn't been thoroughly tested.** We'd rather sit on a good PR for a month than ship a bad one on a Friday.

---

## What this pack is not

Let's start with the part that isn't a criticism, because it's the true part and it gets lost if we bury it.

**All The Mods is a good pack.** We've played it. Plenty of it. Some of us have hundreds of hours in it and they were good hours — it's the reason a pack this size seemed like a thing a person could even attempt, and half of what we know about holding five hundred mods together we learned by watching someone else do it first. If this project has a grandparent, it's that one. Genuine respect, no asterisk.

So when we say spiritual successor, we mean it warmly, and we mean **scale and ambition specifically.** The nerve it takes to say "yes, all of them, and they're going to work together." That's the inheritance and we're proud to claim it.

What we didn't inherit is the blueprint.

The README puts it as well as we're going to: this isn't a kitchen sink pack, it's the entire kitchen — the sink, the cabinets, the fridge, and whatever's quietly growing in the dark behind it. That last part is the bit that's ours. The stuff in the crevices. The mod nobody installs because it looks weird until it's sitting next to nine others and suddenly it's the best thing in your world. A pack that only reproduced its predecessor would never go looking back there.

If your read of "spiritual successor" is "the same thing again," we're going to disagree early and save us both some time. Cloning a pack isn't succeeding it — it's a tribute act or just downright theft. And if all anyone wanted was that pack, it exists, it's still good, it's right there, and it deserves better than a lesser copy of itself with our loading screen bolted on.

**So: nothing below is a shot at them.** The [Code of Conduct](CODE_OF_CONDUCT.md) means what it says about not using this community to take swings at other projects, and that goes double for a pack we actually like. Defining yourself just requires saying what you're not, and this is where we're firm about it.

### The design we're specifically not doing

**No single capstone item that the entire pack points at.** No one ultimate crafting recipe sitting at the end of a tree so deep it becomes the pack's whole identity, where "have you made the star yet" is the only progression question anyone asks. We don't want a pack that funnels every player down one road toward one item, and we especially don't want an endgame whose reward is mostly "you may now stop playing."

**No grind that exists to be grind.** Long is fine. Expensive is fine. A recipe tree that takes real time because it's *teaching you four mods and their interactions* is great — that's the good version and we want more of it. A recipe tree that takes real time because it multiplies a number by nine and then makes you do it again is not the same thing, and it should not be in this pack.

**No joke-item pipeline gated behind hours of automation.** If something's funny, let it be funny. Charging a player an afternoon of setup for a punchline is how a bit becomes a chore.

**No creative-tier items as the finish line.** Handing someone the creative-mode toolbox as a reward for finishing is an odd thing to build toward. It resolves the pack by removing the pack.

### What we want instead

Many roads, running in parallel, none of them mandatory. Progression you can feel at hour three and hour three hundred. Quests that hand you a mod you'd never have touched and give you a reason to like it. An endgame that's about *doing* things — building, automating, fighting something ridiculous — rather than assembling one object and being done.

Everything Ores exists partly for this reason. Unification isn't just a tidiness project; it's what lets a player pick any of nine tech mods and have their materials still mean something, instead of the pack quietly deciding which mod is the real one.

### What this means for your PR

- **"ATM does it" is not a justification.** Neither is "the old pack had one." Tell us why it's good *here*.
- **Don't port their content.** Not their quest books, not their recipes, not their configs. Beyond it being their work with their license attached — see the copypasta rule above, it applies to packs as much as code — it's the exact thing this section exists to prevent.
- **If you're proposing a big grind, show the teaching.** What does the player learn between step one and step twelve? If the answer is "patience," rework it.
- **Big design changes get discussed before they get built.** Open an issue. Nothing worse than someone spending three weekends on a quest chapter that was never going to fit.

We'd rather ship something with its own shape and have people argue about whether the shape is right, than ship a competent tribute act.

---

## Adding mods

The README's [Adding mods](README.md#adding-mods) section is the process. Two things that get PRs bounced:

- **`mr add` when the mod is on both platforms.** Not style. A CurseForge-sourced entry can't be exported to `.mrpack` by reference, so the jar ends up bundled in `overrides/`, which is redistribution, which several licenses here explicitly forbid.
- **`side` is a human call.** The script gets `server` wrong every time, forever, by design — it has no signal to work with. Check it.

New mod PRs should say what the mod adds, why the pack needs it, and whether anything already in the pack does the same job. "It's cool" is a reason but it's not *the* reason at mod #499.

---

## Bug reports

Logs or it didn't happen. Full `latest.log` and the crash report if there is one — not a screenshot of the last four lines, not a paraphrase.

Useful bug report: what you did, what happened, what you expected, the log, your specs, whether it's reproducible, whether it happens on a fresh world.

Less useful: "the pack is broken."

---

## Disagreeing

Push back on decisions. Please. Half the good calls in this pack came from someone saying "that's wrong" and being right about it. Bring the evidence — a log, a profile, a diff — and it's a conversation.

Being right isn't a license to be insufferable about it, and being wrong isn't a crime. We've all shipped a hash mismatch. We've all had to explain to the team why the dev machine needed a hard restart. Nobody here is in a position to be smug.

---

## The short version

| Do | Don't |
|---|---|
| Use AI to help you write code you understand | Vibecode and let us find the bugs |
| Test for hours, days, or weeks | Launch it once and call it green |
| Credit and license borrowed code | Ship a paste and hope |
| Draw it, commission it, or ask for help | Generate it |
| Disclose AI use in the PR | Hide it and get found out |

If you're not sure whether something clears the bar, ask before you build it. Much easier than finding out at review.
