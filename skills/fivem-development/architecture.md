# FiveM Best Practices — Architecture

**Author:** Elias Araújo  
**Part of:** [best-practices.md](best-practices.md) index (one skill: `fivem-development`)  
**Section numbers** (`§1.6.1`, `§2.4`, …) are stable — keep them when linking from audits/corrections.

---

## 3. Code Structure — Architecture

Monolith layout, globals vs locals, state placement. Style/tables/comments → [style.md](style.md).

### 3.5 Resource Layout — Monolith First

**Default structure for a FiveM resource:**

```
resource_name/
├── fxmanifest.lua
├── shared/config.lua
├── server/server.lua
└── client/client.lua
```

Split into extra files **only when**:

- A single file is genuinely hard to navigate (~800–1000+ lines **and** a clear domain boundary), **or**
- Code is shared by multiple resources

**Do not:**

- Create one file per feature, panel, cache, or logger when a `local function` in `server.lua` suffices
- Split client/server like React components — that pattern belongs in NUI (see skill `fivem-react-nui` → `ui-guide.md`), not in Lua scripts

**fxmanifest:** keep `server_scripts` and `client_scripts` minimal.

```lua
-- BAD (over-split)
server_scripts {
    "server/discord.lua",
    "server/cache.lua",
    "server/panel_a.lua",
    "server/panel_b.lua",
    "server/server.lua",
}

-- GOOD (default)
server_scripts {
    "@vrp/lib/utils.lua",
    "server/server.lua",
}
```

### 3.6 Reuse Functions — Avoid Fake Modules

Prefer `local function` in the same file over new globals or extra modules.

| Situation | Do |
|-----------|-----|
| Helper used **once** in the same file | **Inline** at the call site — do not extract ([style.md](style.md) §3.11) |
| Helper used in **2+** handlers/sites in the same file | One shared `local function` — do not duplicate |
| Helper shared across resources | Separate file or shared lib — justified |
| Small cache (names, cooldowns) | `local` table at file top |
| Cache read by **another file in the same resource, same side** (server→server or client→client) | Global or `return` module — justified |

Single-use logic stays **inline** — [style.md](style.md) §3.11. This table is about **where** shared helpers live, not a license to extract every block.

**Globals rule:** a table/function without `local` is OK only when **another script file in the same resource and same runtime side** reads it (per `fxmanifest` — all paths under `server_scripts` share server scope; `client_scripts` share client scope). If the symbol is used **only in the file that declares it**, use `local`.

**Same-resource sharing (critical — do not over-engineer):**

All files in one `server_scripts { ... }` block share the **same Lua environment** (load order = manifest order). To share a module table across those files:

```lua
-- server/database.lua  (listed before consumers in fxmanifest)
ResgateDatabase = {}          -- GLOBAL (no local)
function ResgateDatabase:new() ... end
-- no return

-- server/functions.lua
local db = ResgateDatabase:new()  -- just use it
```

**Forbidden in the same resource / same side:**

```lua
-- WRONG — fake Node-style import (agent anti-pattern)
local chunk = LoadResourceFile(GetCurrentResourceName(), "server/database.lua")
local ResgateDatabase = assert(load(chunk, "@@..."))()
```

Also forbidden for sibling scripts: inventing `require(...)`, `dofile`, or `local X = {}` + `return X` when another file in the same `server_scripts` list needs `X`. Use a **global** or keep logic in one file with `local function`.

Cross-**resource** sharing → `exports` / events / shared lib — never resource globals across resources.

**Audit check for globals:**

1. Read `fxmanifest.lua` — split files into **server scope** vs **client scope** (ignore `shared_scripts` for this rule unless the global is explicitly shared by design).
2. Grep top-level assignments: `^[A-Z][A-Za-z0-9_]*\s*=` and `^function [A-Z]` (exclude `local`).
3. For each symbol, grep all Lua files in the **same scope only**.
4. **Flag** if used in declaring file only → recommend `local`.
5. **Do not flag** if referenced from another file in same scope (e.g. `GarageCache` in `adapter.lua` read by `server/garages.lua`).
6. **Flag** server global read from client file (or vice versa) — wrong pattern; use events, exports, or shared with clear contract.

```lua
-- OK: server/adapter.lua
GarageCache = {}
-- server/spawn.lua reads GarageCache[id]

-- WRONG: only used inside adapter.lua
GarageCache = {}  -- → local GarageCache = {}

-- CORRECT: local helper in server.lua
local identityNameCache = {}
```

Extract to another file only when the boundary is **stable, large, and reused** — not preemptively.

### 3.8 Variable and State Placement

Declare **all** constants and state at the **top** of the file — never scatter new `local` blocks between event handlers.

**Recommended file order** (new files only — do **not** reshuffle an existing file just to match this):

1. Requires / Tunnel / Proxy
2. Constants and state tables (`local ActiveActions = {}`, cooldowns, flags)
3. Local helper functions — **callee before caller** (generic → specific); extract only if 2+ call sites ([style.md](style.md) §3.11)
4. Interface binding (`cRP = {}`, `Tunnel.bindInterface`)
5. Event handlers and `RegisterNetEvent` / NUI callbacks / `CreateThread`

```lua
local Tunnel = module("vrp", "lib/Tunnel")
local Proxy  = module("vrp", "lib/Proxy")

vRP  = Proxy.getInterface("vRP")
vRPC = Tunnel.getInterface("vRP")

local PANEL_COOLDOWN_MS = 5000
local activeActions     = {}
local panelOpen         = false

local function trim(s)
    return tostring(s or ""):gsub("^%s*(.-)%s*$", "%1")
end

local function canOpenPanel(source)
    ...
end

RegisterNetEvent("myresource:openPanel", function()
    if not canOpenPanel(source) then return end
    ...
end)
```

**Wrong:** declaring `local lastOpen = 0` halfway down the file between two `RegisterNetEvent` blocks.

### 3.13 Server-owned entities — who creates, who deletes

Gameplay entities that every player must see the same way (job props, animals, bait, shared work vehicles) are **created by the server, tracked in a table, and deleted by the same resource**. A client-created ped/object is a per-client copy at best and a free item printer for a cheat at worst (D3).

**Which native (server side):**

| Native | Behavior | Use |
|--------|----------|-----|
| `CreateVehicleServerSetter(model, type, x, y, z, heading)` | Created on the server; handle returned immediately | Vehicles |
| `CreatePed(pedType, model, x, y, z, heading, true, true)` | Created on the server; handle returned immediately | Peds / animals |
| `CreateObjectNoOffset(model, x, y, z, true, true, dynamic)` | Created on the server; handle returned immediately. Server side the 7th argument is `dynamic` (physics on/off); there is no heading argument | Props |
| `CreateVehicle` / `CreateObject` | **RPC** — executed by a client; fallible, not guaranteed to run | Avoid for authoritative spawns |

A handle of `0` means creation failed — check it before storing.

**Rules:**

1. **Every handle goes in a table at file top (§3.8) and has a delete path:** area empty, owner left, job finished, `onResourceStop`. A resource that only creates leaks entities for the whole uptime and across every `ensure`.
2. **Culling is not cleanup.** OneSync culling only limits which clients an entity is *sent* to; whether the server itself drops an entity nobody is near depends on its orphan mode. Do not rely on either: delete explicitly, and because the server may have removed it first, **always** `DoesEntityExist(handle)` before using a stored handle. `SetEntityOrphanMode(handle, 2)` (KeepEntity) is only for entities that must outlive every nearby player; then deletion is entirely yours.
3. **Presence is resolved by the server (D3, N5).** A slow server thread compares `GetEntityCoords(GetPlayerPed(src))` with the area. Do **not** count players with client `enter` / `leave` events: they are spam-able (§5.1), forgeable, and a disconnect never sends `leave`, so the counter drifts. If the project already drives this from client zones (`lib.zones` `onEnter` / `onExit`), the server re-checks the coords and keeps a **set keyed by `source`** cleared on `playerDropped` — never a `+1 / -1` counter.
4. **Spawn coords come from config.** The server has no collision or ground lookup — store exact spawn positions; do not compute offsets and hope they are on the ground.
5. **Shared flags on the entity go in its state bag,** set by the server at spawn (performance §1.6.3). Do not mirror what OneSync already syncs (health, position).
6. **The server decides what exists; the owning client moves it.** Server-side `Task*` / `SetEntity*` calls on a ped are RPC to its owner — fallible. Send one event to the owner (or let a state-bag handler start the task) instead of driving movement from the server.
7. **Anti-dupe = server flips the flag before paying.** `if state.skinned then return end; state:set("skinned", true, true)` runs before the reward, in the same handler, on the server.

```lua
-- WRONG: client spawns the shared animal; server counts players by client events
-- client
local deer = CreatePed(28, `a_c_deer`, coords.x, coords.y, coords.z, 0.0, true, true)
TriggerServerEvent("hunting:enteredZone", "paleto")
-- server
RegisterNetEvent("hunting:enteredZone", function(id)
    Zones[id].players = Zones[id].players + 1   -- forgeable; never decremented on disconnect
end)
```

```lua
-- CORRECT: server resolves presence, owns creation and deletion
local Zones = {
    paleto = {
        coords = vector3(-775.0, 5000.0, 130.0),
        spawnRadius = 300.0,
        despawnRadius = 400.0,   -- wider than spawn: no create/delete flapping at the edge
        model = `a_c_deer`,
        spawns = { vector3(-770.2, 5004.5, 130.1), vector3(-781.6, 4992.3, 131.4) },
    },
}
local Spawned = {}   -- [zoneId] = { handle, ... }; nil = nothing spawned

local function clearZone(zoneId)   -- called by the presence thread and onResourceStop
    for _, ped in ipairs(Spawned[zoneId]) do
        if DoesEntityExist(ped) then DeleteEntity(ped) end
    end
    Spawned[zoneId] = nil
end

CreateThread(function()
    while true do
        local players = GetPlayers()
        for zoneId, zone in pairs(Zones) do
            local radius = Spawned[zoneId] and zone.despawnRadius or zone.spawnRadius
            local occupied = false
            for i = 1, #players do
                if #(GetEntityCoords(GetPlayerPed(players[i])) - zone.coords) < radius then
                    occupied = true
                    break
                end
            end

            if occupied and not Spawned[zoneId] then
                local list = {}
                for _, pos in ipairs(zone.spawns) do
                    local ped = CreatePed(28, zone.model, pos.x, pos.y, pos.z, 0.0, true, true)
                    if ped ~= 0 then
                        Entity(ped).state:set("skinned", false, true)
                        list[#list + 1] = ped
                    end
                end
                Spawned[zoneId] = list
            elseif not occupied and Spawned[zoneId] then
                clearZone(zoneId)
            end
        end
        Wait(3000)
    end
end)

AddEventHandler("onResourceStop", function(resource)
    if resource ~= GetCurrentResourceName() then return end
    for zoneId in pairs(Spawned) do clearZone(zoneId) end
end)
```

| Anti-Pattern | Problem | Solution |
|--------------|---------|----------|
| Client `CreatePed` / `CreateObject` for shared gameplay | Different entity per client; cheat can mint it | Server creates (table above) |
| Server creates, nothing deletes | Entity leak across uptime / `ensure` | Tracked table + delete paths (rule 1) |
| Stored handle used without `DoesEntityExist` | Entity may already be gone | Check, drop the stale handle |
| Player counter driven by client `enter` / `leave` events | Forgeable, drifts on disconnect | Server coords check (rule 3) |
| Map-wide spawn "because OneSync culls it" | Culling limits what is sent, not what was created | Spawn only where a player is; despawn when empty |
| Server thread teleporting / tasking a ped every tick | RPC to owner per tick; jitter | One event / state bag → owner runs the task |

**Audit grep hints:** server `Create(Ped|Vehicle|Object)` without a table that stores the handle or without any `DeleteEntity`; missing `onResourceStop` in a resource that spawns; client `CreatePed(` / `CreateObject(` with `isNetwork = true` for job/shared entities; `RegisterNetEvent` names containing `enter` / `leave` / `exit` that only increment or decrement.
