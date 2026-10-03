# Forge Everything — Server Setup

Minecraft 1.21.1 · NeoForge 21.1.234 · ~442 server-side mods

This package is small on purpose. It contains no mods and no configs — those are
downloaded from the pack repository the first time you start the server, and
re-synced on every start after that. When the pack updates, you get the update
by restarting. There is nothing to re-download here.

## Requirements

- **Java 21** (Oracle, Zulu, Temurin — any distribution)
- **12 GB RAM minimum** on the host. This is a ~442-mod pack; it will not behave
  with less in it's current state
- Roughly 10 GB disk for mods, libraries, and world data

## Setup

**1. Install the NeoForge server**

Download the NeoForge **21.1.234** installer from https://neoforged.net/ and run:

```
java -jar neoforge-21.1.234-installer.jar --installServer
```

This creates `run.bat` / `run.sh`, `libraries/`, and `user_jvm_args.txt` in the
current folder. Do this in the folder you want the server to live in.

**2. Copy in the files from this package**

- `packwiz-installer-bootstrap.jar`
- `start.bat` (Windows) or `start.sh` (Linux/macOS)
- `user_jvm_args.txt` — **overwrite** the one the installer generated

**3. Edit two things**

In `start.bat`, set `JAVA` to the same `java` executable your `run.bat` uses.
On Linux, edit `JAVA` in `start.sh` if `java` is not on your `PATH`.

In `user_jvm_args.txt`, set `-Xmx` and `-Xms` to match your host. 12G is the floor for this pack;
raise it if you have the memory, but always leave several GB for the OS.

**4. Accept the EULA**

Run `start.bat` once. It will fail and generate `eula.txt`. Open it, change
`eula=false` to `eula=true`, and run again.

**5. Start**

```
start.bat        (Windows)
./start.sh       (Linux/macOS)
```

First start downloads ~442 mods and takes several minutes. Later starts sync
only what changed.

Open port **25565** if players are connecting from outside your network.

## Day-to-day

**Always launch with `start`, never `run` directly.** `run.bat` skips the sync,
so the server would silently keep running an old mod set while clients update —
producing connection failures that look like a pack bug rather than a stale
server.

If you use an auto-restart wrapper, point it at `start`, not `run`, for the same
reason.

## Troubleshooting

**"Pack sync FAILED"**
No internet, or GitHub is unreachable. The script stops rather than starting
with a partial mod set. Check connectivity and retry.

**Clients can't connect, mismatch errors**
The server is running an older sync than the clients. Restart it via `start`.

**Out of memory**
Raise `-Xmx`. If you're already at the host's limit, this pack needs a bigger
host — there isn't a tuning fix for 442 mods on 8 GB (yet).

## Notes

- Client-only mods (Sodium, Iris, minimaps, and so on) are excluded automatically
  by the `-s server` flag in the start script. Don't remove it.
- The pack, its configs, and this server package all come from:
  https://github.com/Rexilyent/forge-everything
