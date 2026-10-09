# FiveM Best Practices — Game Versions (Legacy vs Enhanced)

**Part of:** [best-practices.md](best-practices.md) index (one skill: `fivem-development`)  
**Source:** [What's Changed in FiveM for GTAV Enhanced](https://docs.fivem.net/docs/developers/legacy-vs-enhanced/) (Cfx.re docs) — read 2026-10-08, during early access.  
**Section numbers** (`§6.1`–`§6.4`) are stable — keep them when linking from audits/corrections.

---

## 6. Game versions

FiveM runs on two game versions:

| | FiveM (Legacy) | FiveM for GTAV Enhanced |
|---|---|---|
| Game | GTA V Legacy | GTA V Enhanced |
| Status | Supported | **Early access** since 2026-07-21 — bugs and missing features expected |
| Server binary | `FXServer.exe` | `cfx-server.exe` (archive `cfx-server_win_x64` / `cfx-server-linux_x64`) |
| Cross-play | — | None: a Legacy client cannot join an Enhanced server and vice versa |

Migrating is optional. Existing Lua / JS / C# scripts are meant to keep working; the differences below are what a script author can still trip over.

### 6.1 Which version is the project on?

Hints, not proof — **ask the user when the answer changes the code**:

- `cfx-server.exe` / `cfx-server_*` artifacts → Enhanced; `FXServer.exe` → Legacy
- `stream_enhanced/` folders in resources → targets Enhanced (possibly both)
- `sv_syncTickRate` in `server.cfg` → Enhanced
- C# resources on .NET 10 → Enhanced; Mono → Legacy

**Unknown → write code that is correct on both** (the "Write" column in §6.2 already is).

### 6.2 Changes that affect scripts

| Area | Legacy | Enhanced | Write (safe on both) |
|------|--------|----------|----------------------|
| **Server IDs** | Only increment, wrap 65535 → 1 | "An ID is released when a player disconnects and can be reused by the next player who connects" (marked as subject to change) | Every table keyed by `source` (cooldowns, sessions, zone sets, pending trades) is cleared on `playerDropped` / the framework leave hook. Persist and compare the character id (Passport, citizenid, identifier), never `source` |
| **OneSync** | Big and non-big modes; P2P sync | Big mode only; P2P removed. Player connect/disconnect events only arrive when the player is in range | Do not build a full player list on the client from those events — the server owns the list (`GetPlayers()`) and pushes what the client needs (performance §2.2.1) |
| **State bags** | — | "Callbacks only fire if the entity exists"; "replicated values are only replicated if explicitly set" | Handler returns early on `0` (performance §1.6.3 rule 3). When a value must replicate, set it with the flag explicit — `state:set(key, value, true)` — not the `state.key = value` shorthand; the docs do not detail which forms count as explicit |
| **Streaming** | `stream/` | `stream_enhanced/` used instead of `stream/` when present; `stream/` is the fallback (deprecated, still works) | Gen8 assets in `stream/`, Gen9 assets in `stream_enhanced/` |
| **Builders** | Resources can be builders | "Resources can no longer be builders" | Build NUI / JS bundles outside the server (Vite `build`) and ship the output — [fivem-react-nui](../fivem-react-nui/SKILL.md) |
| **C#** | Mono | .NET (requires .NET 10 SDK) | Check the target before choosing APIs |
| **Commands** | No unregister | `UnregisterCommand(id)` with the id returned by `RegisterCommand`; remote command output goes to the client only through `PrintRemoteCommandLog(message)` | Enhanced-only — do not use when the project must run on Legacy |
| **Entity lockdown** | — | New `full` mode (disables dummy object creation); in `relaxed`, population entities spawn only if the player owns the world grid | Gameplay entities are server-created (architecture §3.13) — unaffected |
| **KVP** | — | Key-value DB files must be migrated (migration script planned) | Data written with `SetResourceKvp*` does not carry over by itself |
| **Game build** | `sv_enforceGameBuild <build>` | Only the latest build (The Kortz Center Heist); `sv_enforceGameBuild 1` loads the base game without DLCs | Do not copy a Legacy `sv_enforceGameBuild` value into an Enhanced `server.cfg` |
| **Asset Escrow** | Available | Not implemented yet | Escrowed (paid) resources do not run on Enhanced yet |

**Convars:** `sv_syncTickRate` (new; default 60, range 1–120; higher = lower latency, more CPU) replaces `sv_useAccurateSends` (deprecated). `onesync_enableBeyond` is a no-op. `sv_protectServerEntities` is not implemented — use `sv_entityLockdown`. Removed: `onesync_automaticResend`, `sv_netHttp2`, `+set moo 31337` (use `sv_devMode true`). Pure mode is always on.

### 6.3 Rules

1. **Target unknown → safe-on-both code** (§6.1, §6.2 "Write" column). Never assume Enhanced only because it is newer.
2. **Enhanced is early access.** Anything about Enhanced that is not in §6.2 → **FETCH** the source page before stating it; never fill gaps with Legacy behavior or with guesses (No Hallucination Policy, [SKILL.md](SKILL.md)).
3. **Enhanced-only APIs and convars** (`UnregisterCommand`, `PrintRemoteCommandLog`, `sv_syncTickRate`) only when the project confirmed Enhanced.
4. **`source` is a connection, not a player** — on both versions; ID reuse on Enhanced only turns a stale entry from a leak into another player's data (security §5.1).

### 6.4 Migration audit (Legacy → Enhanced)

Grep the resource, report each hit with `file:line`:

| Grep | Risk on Enhanced |
|------|------------------|
| Tables indexed by `source` / `src` with no clear on `playerDropped` | Next player inherits cooldown / session / ownership |
| `source` stored in DB, KVP, or a table used as identity | Points to another player after reuse |
| `stream/` with Gen8-only assets | Needs a `stream_enhanced/` counterpart |
| `.state.key = value` shorthand or `state:set(` without the third argument for values clients read; handlers without the `0` guard | Value may not replicate; handler on a missing entity |
| Client-side player list built from connect/disconnect events | Only players in range arrive |
| C# resource on Mono APIs | Port to .NET 10 |
| `SetResourceKvp` / `GetResourceKvp` | Data needs the KVP migration |
| Builder resource (webpack / yarn builder) | No longer runs — prebuild |
| Escrowed dependency | Does not run yet |
