# FiveM Best Practices — Performance & Cache

**Author:** Elias Araújo  
**Part of:** [best-practices.md](best-practices.md) index (one skill: `fivem-development`)  
**Section numbers** (`§1.6.1`, `§2.4`, …) are stable — keep them when linking from audits/corrections.

---

## Network & tick cost (§1.4–§1.6.1)

> Protocol choice (Tunnel vs event, `_` prefix, same-side calls) stays in [communication.md](communication.md) §1.1–§1.3 / §1.7.  
> Below: **when** and **how heavy** those calls are — loops, sleep, payload size, broadcast targets.

### 1.4 Avoid Remote Calls in Loops

```lua
-- WRONG: callback in high frequency loop
while true do
    ServerCallback.updatePosition()
    Wait(100)
end

-- CORRECT: larger interval
while true do
    TriggerServerEvent("player:position", GetEntityCoords(PlayerPedId()))
    Wait(5000)
end

-- BETTER: send only when necessary
local lastPosition = nil
while true do
    local pos = GetEntityCoords(PlayerPedId())
    if lastPosition == nil or #(pos - lastPosition) > 10.0 then
        TriggerServerEvent("player:position", pos)
        lastPosition = pos
    end
    Wait(100)
end

-- ALTERNATIVE: data batch
local positions = {}
while true do
    table.insert(positions, GetEntityCoords(PlayerPedId()))
    if #positions >= 10 then
        TriggerServerEvent("player:positions_batch", positions)
        positions = {}
    end
    Wait(100)
end
```

#### N+1 remote call — loop client → server por item

```lua
-- WRONG: 1 chamada Tunnel + 1 query por preset (N+1)
for _, preset in ipairs(presets) do
    Wait(120)
    local shot = func.getScreenshot(preset.id)
    SendNUIMessage({ action = "screenshot", id = preset.id, data = shot })
end

-- CORRECT: uma chamada batch (ou já incluir o campo no payload da lista)
local shots = func.getScreenshots(presetIds)  -- server: WHERE id IN (...)
for id, shot in pairs(shots) do
    SendNUIMessage({ action = "screenshot", id = id, data = shot })
end
```

**Before any position sync (N5):** with OneSync the server reads `GetEntityCoords(GetPlayerPed(src))` and other clients read coords natively — an event that only reports position is usually unnecessary.

**Audit grep:** loop no client que chama `func.*` / `ServerCallback` / `TriggerServerEvent` por item de uma lista recebida na mesma sessão. Fix: endpoint batch (`ids[]` → `WHERE id IN (...)`) ou incluir o campo no payload da lista; veja também §2.1.1 (client-side cache).

### 1.5 Mandatory Dynamic Sleep

**NEVER use fixed `Wait(0)`.** Adjust sleep based on current state.

```lua
-- WRONG
CreateThread(function()
    while true do
        Wait(0)  -- RUNS 60x/s, ALWAYS
        if IsPedArmed(PlayerPedId(), 6) then
            DisableControlAction(1, 140, true)
        end
    end
end)

-- CORRECT
CreateThread(function()
    while true do
        local sleep = 1500
        local ped = PlayerPedId()
        if IsPedArmed(ped, 6) then
            sleep = 0  -- Armed: needs to run every frame
            DisableControlAction(1, 140, true)
            DisableControlAction(1, 141, true)
            DisableControlAction(1, 142, true)
        end
        Wait(sleep)
    end
end)
```

**Recommended Sleep Table:**

| Situation | Sleep |
|----------|-------|
| Constant check (DisableControl, DrawText) | `0` |
| Player armed/in vehicle | `0-10` |
| State check (health, position) | `100-500` |
| Occasional check (zone, weather) | `1000-2000` |
| Rare check (configs, permissions) | `5000+` |

### 1.5.1 Distance checks — vector math + split threads

Dynamic sleep (§1.5) decides **how often** a thread runs. This section is about **what one iteration costs**: every native call crosses Lua → engine, so a per-frame loop that walks a whole config table pays that cost × items × 60.

**Rules (T2):**

1. **Distance = vector math.** `#(a - b)` (3D) or `#(a.xy - b.xy)` (2D). Never `GetDistanceBetweenCoords` / `Vdist` — the native reference itself lists the vector form as the faster equivalent.
2. **Read the ped and its coords once per iteration**, outside the item loop — never per item.
3. **Split the work:** a slow thread scans the full list and keeps only what is near; the per-frame thread touches only that short list and sleeps when it is empty.
4. **ox_lib ensured in the project** → `lib.points` / `lib.zones` replace the hand-written scan (see `qbox-framework`). Do not add ox_lib as a dependency only for this.
5. **The frame thread holds only per-frame work:** natives that must run every frame (`*ThisFrame`, `Draw*`, `DisableControlAction`). State reads (`IsPedDeadOrDying`, `IsPedInAnyVehicle`, …) run in the slow thread and are stored in locals the frame thread reads.
6. **Do not cache `PlayerPedId()` for the lifetime of a thread.** The handle changes on respawn and model change; re-read it each slow-thread iteration (it is cheap at 500 ms).

```lua
-- WRONG: native distance, full list, every frame
CreateThread(function()
    while true do
        Wait(0)
        for _, point in pairs(Points) do
            local coords = GetEntityCoords(PlayerPedId())
            if GetDistanceBetweenCoords(coords.x, coords.y, coords.z, point.coords.x, point.coords.y, point.coords.z, true) < 20.0 then
                DrawMarker(2, point.coords.x, point.coords.y, point.coords.z, 0.0, 0.0, 0.0, 0.0, 180.0, 0.0, 1.0, 1.0, 1.0, 200, 20, 20, 50, false, true, 2, nil, nil, false)
            end
        end
    end
end)

-- CORRECT: slow scan builds the short list; the frame loop only draws it
local Nearby = {}

CreateThread(function()
    while true do
        local coords = GetEntityCoords(PlayerPedId())
        local found = {}
        for _, point in pairs(Points) do
            if #(coords - point.coords) < 20.0 then
                found[#found + 1] = point.coords
            end
        end
        Nearby = found
        Wait(500)
    end
end)

CreateThread(function()
    while true do
        local sleep = 500
        for i = 1, #Nearby do
            sleep = 0
            local c = Nearby[i]
            DrawMarker(2, c.x, c.y, c.z, 0.0, 0.0, 0.0, 0.0, 180.0, 0.0, 1.0, 1.0, 1.0, 200, 20, 20, 50, false, true, 2, nil, nil, false)
        end
        Wait(sleep)
    end
end)
```

| Anti-Pattern | Problem | Solution |
|--------------|---------|----------|
| `GetDistanceBetweenCoords` / `Vdist` in a loop | Native call per item per tick | `#(a - b)` |
| `PlayerPedId()` / `GetEntityCoords` inside the item loop | Same value fetched N times | Read once per iteration |
| `Wait(0)` thread iterating every point/shop/garage | Cost grows with config size, even far away | Slow scan → short list → frame loop (or `lib.points`) |
| State natives (`IsPedDeadOrDying`, `IsPedInAnyVehicle`) read inside the `Wait(0)` thread | Native calls every frame for values that change rarely | Slow thread writes locals; frame thread reads them (rule 5) |
| `local ped = PlayerPedId()` once before `while true` | Stale handle after respawn / model change | Re-read in the slow thread (rule 6) |
| Enumerating world entities (`FindFirstPed` / `FindNextPed`) every frame | Walks the whole pool 60×/s | Slow interval (≥ 500 ms) |
| `Citizen.CreateThread` / `Citizen.Wait` / `GetPlayerPed(-1)` in new code | Legacy aliases; inconsistent with the rest of the file | `CreateThread` / `Wait` / `PlayerPedId()` — do not rewrite untouched legacy code just for this (§3.11) |

**Audit grep hints:** `GetDistanceBetweenCoords`, `Vdist`, and any `Wait(0)` thread whose body has `pairs(` / `ipairs(` over a config or synced table.

### 1.5.2 Lua in the hot path — measured on Lua 5.4

Natives and network (§1.5–§1.6) dominate a resource's cost. Pure-Lua micro-optimizations matter **only** inside a per-frame (`Wait(0)`) thread, a loop over a large list, or a handler that runs for every player — never apply them to code that runs once or on a timer (§2.6 rule 1: judge by behavior, not by guesses). Readability wins everywhere else.

**Measured** (Lua 5.4 interpreter, 5 M iterations, best of 5 runs; port of the [Spring RTS Lua Performance](https://springrts.com/wiki/Lua_Performance) tests, which were Lua 5.1 — their percentages do not apply to FiveM). CfxLua adds its own extensions, so treat the ratios as a guide, not as FiveM ms. Reproduce with `lua tools/lua-performance-bench.lua` in the repo:

| Rule (hot path only) | Slow | Fast | Measured |
|----------------------|------|------|----------|
| **Do not create functions inside a loop** | `f(x, function(a) ... end)` per iteration | `local function` defined once, passed by name | closure per iteration **2.5×** slower + garbage |
| **Pre-size table constructors** | `local t = {}` then `t[1] = … t[2] = …` | `{a, b, c}` / `{x = 1, y = 2}` | array **2.6×**, hash **2.1×** |
| **No new table per frame** | `{...}` built inside `Wait(0)` | Build once outside the loop, reuse — only if it is never mutated (shared = same object) | new 3-item table **18×** vs reusing one |
| **Strings: `table.concat`** | `s = s .. part` in a loop | `parts[#parts + 1] = part` → `table.concat(parts)` | 1000 parts: **7.3×** |
| **Arrays: numeric `for`** | `pairs` / `ipairs` | `for i = 1, #t do local v = t[i]` | `ipairs` **2.8×**, `pairs` **3×**. Caching `#t` makes no difference. `pairs` stays for hash tables |
| **Append without a call** | `table.insert(t, v)` | `t[#t + 1] = v` or a counter | `table.insert` **2.6×**; `#t + 1` 1.4×; counter 1.07× |
| **Compare, do not call** | `math.max(a, b)` / `math.min` | `if a > b then …` | **2.9×** |
| **`%` instead of `math.fmod`** | `math.fmod(i, n)` | `i % n` (same result for positive numbers only) | **3.2×** |
| **Read `t[i]` once** | `t[i].x = t[i].x + 1` | `local v = t[i]; v.x = v.x + 1` | 1.3× |
| **Localize globals in hot files** | `math.min` / a global function per call | `local min = math.min` at file top | 1.2–1.3× — natives are globals, but the native call itself costs far more than the lookup |
| **`x or default`** | `if x == nil then y = d else y = x end` | `local y = x or d` | 1.3× — **wrong when `x` can be `false`** (gives `d`) |

**No measurable difference — do not "fix":** `x^2` vs `x*x`, `t["foo"]` vs `t.foo`, `local f = obj.method` before calling it, caching `#t` in a local.

| Anti-Pattern | Problem | Solution |
|--------------|---------|----------|
| `AddEventHandler` / `RegisterNetEvent` / `CreateThread` inside a loop or another handler | A new handler / thread on every pass: duplicate execution and leak, not just slowness | Register once at file top |
| Table / string built inside `Wait(0)` | Garbage every frame → GC pauses (hitches) | Build once, reuse; `table.concat` |
| Micro-optimizing code that runs once or every few seconds | Less readable, no measurable gain | Leave it (§3.11) |

**Audit grep hints:** `function(` as an argument inside `for` / `while` bodies; `AddEventHandler` / `RegisterNetEvent` / `CreateThread` nested in a loop or handler; `{` constructors and `..` concatenation inside `Wait(0)` threads; `table.insert` / `ipairs` / `math.max` inside per-frame loops.

### 1.6 Payloads in Events

FiveM Limits:

| Type | Limit |
|------|--------|
| Single Event | ~16 KB (recommended < 8 KB) |
| Network buffer per tick | ~64 KB |
| Nested table | Max 16 levels |

```lua
-- WRONG: send full inventory when 1 item changes
TriggerClientEvent("inventory:full", source, fullInventory)

-- CORRECT: send only the change
TriggerClientEvent("inventory:addItem", source, { item = "water", amount = 1 })

-- For large data: divide into chunks
local function sendInChunks(source, data, chunkSize)
    local chunks = {}
    local current = {}
    local count = 0
    for k, v in pairs(data) do
        current[k] = v
        count = count + 1
        if count >= chunkSize then
            table.insert(chunks, current)
            current = {}
            count = 0
        end
    end
    if count > 0 then table.insert(chunks, current) end
    for i, chunk in ipairs(chunks) do
        TriggerClientEvent("sync:chunk", source, chunk, i, #chunks)
        Wait(100)
    end
end
```

**Signs of problem:** `Network overflow` in console, players disconnecting, lag spikes.

#### Respostas Tunnel/callback (`tunnel_res`) seguem o mesmo budget

O retorno de uma chamada Tunnel/callback viaja pelo mesmo canal de rede — o cerberus o reporta como `OUT:<resource>:tunnel_res`. **Os limites acima valem para respostas também**: uma resposta de 290 KB é 35× o budget de um evento e pode derrubar jogadores.

Regras para endpoints de leitura:

1. **Lista retorna só metadados** — `load*`/`list*` retorna campos leves (id, nome, data). Campos pesados (screenshot LONGTEXT, JSON de roupa, imagens) ficam fora da lista.
2. **Detalhe pesado sob demanda** — por item selecionado (`getDetail(id)`), ou em **batch** se a UI precisa de todos (`getDetails(ids[])`); nunca N+1 (§1.4).
3. **Resposta > ~64 KB → repensar** — dividir, cachear no client (§2.1.1), ou entregar via cerberus `SendFullSync` quando for bootstrap grande.

### 1.6.1 Broadcast targets — `source` vs `-1` vs cerberus

Choose the target by **audience** (who must receive) and **payload size** (how much data).

| Target | When to use | Payload size |
|--------|-------------|--------------|
| `source` | One player — UI/NUI reply, admin panel, personal bootstrap | Any (prefer < 8 KB) |
| `-1` | **Global world sync** — all clients must apply the same small change (blip, zone, delete id) | **Small only** (< ~8 KB recommended) |
| `SendDeltaSync` / `SendFullSync` | Many players + large table, or need **scope** (`range`, `scopeRadius`, chunking) | Any — cerberus handles load balance |

**Rules:**

1. **`-1` is for global gameplay state**, not admin/manager UI. Events like `manager:*`, panel refresh, or staff-only data → **`source`** (or explicit admin source list).
2. **Small delta to everyone** → `TriggerClientEvent("world:updateX", -1, smallPayload)` or cerberus `SendDeltaSync(-1, ...)` when payload is tiny.
3. **Large sync to everyone or scoped area** → cerberus with `coords`, `range`, `scopeRadius` when the project ensures cerberus; otherwise pre-built chunks per §2.2.1. Never one `TriggerClientEvent(-1, hugeTable)`.
4. **Bootstrap one player** → server push from the player-loaded hook with the pre-built view cache (§2.2.1). The client never requests its initial data.

```lua
-- WRONG: admin UI broadcast to all players
TriggerClientEvent("manager:garageUpdated", -1, ManagerGarageListCache[id])

-- CORRECT: admin UI → only the admin client
TriggerClientEvent("manager:garageUpdated", source, ManagerGarageListCache[id])

-- CORRECT: world blip/zone sync → all players, small payload
TriggerClientEvent("garages:updateGarage", -1, {
    id = tostring(id), x = coords.x, y = coords.y, z = coords.z, spawns = spawns
})

-- CORRECT: large cache bootstrap near player
exports["cerberus"]:SendFullSync(source, "garages:fullSync", SanitizedGarageCache, {
    key = "garages:bootstrap",
    coords = GetEntityCoords(GetPlayerPed(source)),
    range = 150.0
})

-- CORRECT: delta to all, small entry (alternative to TriggerClientEvent -1)
exports["cerberus"]:SendDeltaSync(-1, "garages:updateGarage", ViewCache[id])
```

| Anti-Pattern | Problem | Solution |
|--------------|---------|----------|
| `TriggerClientEvent("manager:*", -1, ...)` | Leaks admin data to every client | `source` only |
| `TriggerClientEvent(-1, hugeTable)` | Network overflow, tick spikes | cerberus `SendFullSync` / `SendDeltaSync` + scope options |
| Chunk loop that rebuilds/sanitizes the payload per call or per player | Same work repeated N times | Chunks split once from the view cache (§2.2.1), or cerberus when ensured |

### 1.6.2 StateBags — replication cost (`GlobalState` / entity / player)

State bags are **replicated network state**. Every write that replicates is roughly like a small broadcast — worse when the value is large or changes every frame/tick.

| Bag | Replicates to | Cost if churned |
|-----|---------------|-----------------|
| `GlobalState.key = value` | **All clients** | Highest — treat like `TriggerClientEvent(-1, …)` |
| `Entity(ent).state:set(k, v, true)` / replicated player state | Clients that care about that entity/player (still network) | High if many entities or high frequency |
| Local / non-replicated (`replicate = false`) | Nobody else | Safe for hot local loops |

**Rules:**

1. **Never** write `GlobalState` or replicated bags inside `Wait(0)` / per-frame loops, position ticks, or spam-able net events.
2. **Debounce / threshold** — only set when the value **actually changed** (and preferably when change > epsilon for numbers/coords).
3. **Keep values tiny** — ids, flags, enums. Do **not** stuff full inventories, shop tables, or JSON blobs into StateBags; use events/cerberus/view cache instead.
4. **Server-authoritative writes** for shared world flags. Client-driven replicated bags are an exploit + flood surface (pair with Pass 2b / SafeEvent).
5. Prefer **one bag update per logical state change** (door open/closed), not continuous telemetry (use a throttled event or local-only state for that).

```lua
-- WRONG: GlobalState every tick → all clients get a bag update continuously
CreateThread(function()
    while true do
        GlobalState.serverTime = os.time()
        Wait(0)
    end
end)

-- WRONG: replicated bag from a client-spamable event
RegisterNetEvent("hud:setBusy")
AddEventHandler("hud:setBusy", function(busy)
    GlobalState["busy:" .. source] = busy  -- cheat loop = global replication storm
end)

-- CORRECT: write only on change; rare global flags
local lastWeather = nil
function setWeather(name)
    if lastWeather == name then return end
    lastWeather = name
    GlobalState.weather = name  -- infrequent, small value
end

-- CORRECT: high-frequency data stays local or uses throttled events — not GlobalState
LocalPlayer.state:set("nearestDoor", doorId, false)  -- replicate=false
```

| Anti-Pattern | Problem | Solution |
|--------------|---------|----------|
| `GlobalState` / replicated `:set(..., true)` in a tight loop | Network saturation, hitch for every player | Local state, throttle, or event delta |
| Large table in a state bag | Fat replication payload | Tiny keys; sync bulk via cerberus/events |
| Client event → write `GlobalState` without rate-limit | Cheat amplification (same class as E-b) | Server auth + SafeEvent; avoid GlobalState for per-player noise |
| Using bags as a full data bus | Hidden `-1`-class traffic | Bags = small flags; caches/events for data |

**Audit grep hints:** `GlobalState`, `.state:set`, `LocalPlayer.state`, `Player(..).state`, `Entity(..).state`.

### 1.6.3 StateBags — react with a change handler, do not poll

§1.6.2 is the **cost** side (what a write costs). This is the **read** side: a small, long-lived flag that other code needs to notice (cuffed, on duty, siren muted, door locked) is consumed with `AddStateBagChangeHandler` — the script stays idle until the value changes (T1). A thread that re-reads the flag on a timer is polling.

**What belongs in a bag:**

| Bag | Good fit (small, changes rarely) | Never |
|-----|----------------------------------|-------|
| `Player(src).state` | `isCuffed`, `onDuty`, `inSafeZone` | Inventory, money, any table that grows |
| `Entity(ent).state` | `isLocked`, `sirenMuted`, `skinned`, a small counter such as hits left | Coords, speed, RPM, health — OneSync already syncs them |
| `GlobalState` | Weather id, event flag, XP multiplier | Per-player data (§1.6.2) |

**Rules:**

1. **Server writes, clients react (D3).** Default write permissions: player state = that player + server; entity state = the owning client + server; `GlobalState` = server. A client therefore **can** write its own player bag and the bags of entities it owns — never treat a bag value as proof of anything. The client asks through a validated endpoint (§5.1–§5.3); the server writes the bag. A project where every write is server-side can enforce it with `setr sv_stateBagStrictMode true`.
2. **Use the `value` argument.** Inside the handler the bag still holds the **previous** value; reading `state[key]` there returns stale data. The handler cannot reject a change.
3. **Never parse `bagName`.** It is an internal id. Resolve it with `GetEntityFromStateBagName(bagName)` / `GetPlayerFromStateBagName(bagName)`; both return `0` when the bag is not of that kind **or the entity/player does not exist on this machine yet** — return early on `0`.
4. **Flat keys only.** `state.a.b = x` does not replicate and nested reads deserialize the whole value every time. Set the whole value or use a flat key (`state["a:b"] = x`).
5. **A bag is not storage.** The server table / DB stays the source of truth; the bag is the replicated flag derived from it.
6. **Per-frame work lives behind the flag.** If the flag requires `Wait(0)` work while it is on (disabling controls), the handler starts that thread and the thread ends itself when the flag turns off.

```lua
-- WRONG: polls a flag forever; costs CPU while nothing changes
CreateThread(function()
    while true do
        Wait(0)
        if LocalPlayer.state.isCuffed then
            DisableControlAction(0, 24, true)
            DisableControlAction(0, 25, true)
        end
    end
end)

-- WRONG: parses bagName by hand and compares a network id with a local handle
AddStateBagChangeHandler("isCuffed", nil, function(bagName, key, value)
    local id = tonumber((bagName:gsub("entity:", "")))
    if id ~= PlayerPedId() then return end
end)
```

```lua
-- CORRECT — server: the only writer, after its own checks
Player(target).state:set("isCuffed", true, true)

-- CORRECT — client: idle until the flag changes; frame loop exists only while cuffed
local cuffed = false

AddStateBagChangeHandler("isCuffed", nil, function(bagName, key, value)
    if GetPlayerFromStateBagName(bagName) ~= PlayerId() then return end

    local wasCuffed = cuffed
    cuffed = value == true
    if not cuffed or wasCuffed then return end

    CreateThread(function()
        while cuffed do
            DisableControlAction(0, 24, true)
            DisableControlAction(0, 25, true)
            Wait(0)
        end
    end)
end)
```

```lua
-- CORRECT — entity flag: every client in scope applies it once per change
AddStateBagChangeHandler("sirenMuted", nil, function(bagName, key, value)
    local vehicle = GetEntityFromStateBagName(bagName)
    if vehicle == 0 then return end
    SetVehicleHasMutedSirens(vehicle, value == true)
end)
```

**Rule (N5):** on GTAV Enhanced, state bag callbacks fire only if the entity exists, and values replicate only when explicitly set — keep the `0` guard and write replicated values with `state:set(key, value, true)` ([game-versions.md](game-versions.md) §6.2).

`AddStateBagChangeHandler(keyFilter, bagFilter, handler)` returns a cookie; a handler registered for a temporary feature is removed with `RemoveStateBagChangeHandler(cookie)`.

| Anti-Pattern | Problem | Solution |
|--------------|---------|----------|
| Thread re-reading `*.state.x` on a timer | Polling; CPU while idle | `AddStateBagChangeHandler` on that key |
| `bagName:gsub(...)` / `tonumber(bagName)` | Internal format; network id ≠ local handle | `GetEntityFromStateBagName` / `GetPlayerFromStateBagName`, return on `0` |
| Reading `Entity(e).state[key]` inside its own handler | Still the old value | Use the `value` argument |
| Server trusts a bag the client can write | Client-forged state | Server keeps its own table; bag is output only (rule 1) |
| `playerEnteredScope` / `playerLeftScope` to push per-entity data | Fires once per player pair; the docs recommend bags + handler instead | Entity/player bag + handler |
| Bag used to replace a one-shot action (notify, play sound once) | Bags are state, not messages | Event to the right target (§1.6.1) |

**Audit grep hints:** `while` threads that read `.state.` every iteration; `AddStateBagChangeHandler` bodies containing `gsub` / `tonumber(bagName`; server handlers that read `Player(source).state` / `Entity(..).state` as authorization.

## 2. Data Cache

### 2.1 cacheaside — In-Memory Cache with TTL

Database queries are expensive operations. Use cache for repeatedly queried data.

```lua
-- WRONG: query every time
exports("checkRelation", function(playerId)
    local result = MySQL.query.await("SELECT * FROM relationship WHERE player_id = ?", { playerId })
end)

-- CORRECT: using cacheaside
exports("checkRelation", function(playerId)
    local Consult = exports.cacheaside:Get("relationship:findRelationship", playerId, {
        query = { "SELECT * FROM relationship WHERE player_id = ?", { playerId } },
        default = {}
    })
    if Consult[1] and Consult[1]["status"] == 3 then
        return true, Consult[1]["other_id"]
    end
    return false
end)
```

**Cacheaside API:**

| Function | Description |
|--------|-----------|
| `Get(namespace, key, opts)` | Fetches from cache or executes query |
| `Set(namespace, key, value, ttl)` | Saves value to cache (TTL optional, seconds) |
| `Delete(namespace, key)` | Removes specific item |
| `FlushNamespace(namespace)` | Clears entire namespace |
| `GetNamespace(namespace)` | Returns all entries in a namespace |

**Get Options:**
```lua
exports.cacheaside:Get("namespace", "key", {
    query = { "SQL", { params } },  -- query if cache miss
    ttl = 300,                       -- TTL in seconds
    default = {},                    -- default value
    forceRefresh = false,            -- force fetch from DB
    logger = true                    -- activate logs
})
```

**Install:** add `ensure cacheaside` in `server.cfg` before resources that depend on it. Recommended: **oxmysql** for the `query` option in `Get`.

**When to use cache:**

| Situation | Use Cache? |
|----------|-------------|
| Data that changes rarely (configs, ranks) | Yes |
| Repeated queries in short period | Yes |
| Real-time data (position, health) | No |
| Data that changes with every player action | No |

**Invalidating cache:**
```lua
exports.cacheaside:Delete("relationship:findRelationship", playerId)
exports.cacheaside:Set("relationship:findRelationship", playerId, newValue, 300)
```

**Rule (D1):** a per-user lookup (slots, ranks, permissions) read by 2+ endpoints goes through `cacheaside:Get` and is invalidated (`Set`/`Delete`) in the endpoint that mutates it — never re-queried per call. Case: wardrobe queried `extra_slots` in `loadPresets`, `refresh` and `saveOutfit` (3× E-a); fix = one cached read, `Set` on slot purchase.

### 2.1.1 Client-side cache — reduzir round-trips ao server

Dados de UI que mudam pouco (presets, configuração do próprio jogador, listas pessoais) não precisam ser rebuscados no server a cada abertura/refresh. Cacheie no **client** e invalide apenas quando o próprio jogador alterar.

**Padrões:**

| Padrão | Regra |
|--------|-------|
| **Fetch on open** | Ao abrir a UI, buscar **uma vez** (metadados + detalhes em batch). Guardar em tabela local do client. |
| **Save-through** | Ao editar: atualiza a cópia local **e** persiste no server na mesma ação. UI nunca fica à frente/atrás. |
| **Invalidar no CRUD** | create/update/delete bem-sucedido → atualiza ou remove a entrada no cache local (não rebusca a lista inteira). |
| **Detalhe em batch** | Precisa de N detalhes (ex. screenshots) → **1 chamada** `getDetails(ids[])`, não N chamadas (§1.4 N+1). |
| **Gerar no client** | Se o dado pode ser produzido localmente (ex. foto do próprio ped via `screenshot-basic`), prefira gerar no client a buscar bytes do server. |

```lua
-- client.lua
local presetsCache = nil

local function openUi()
    if not presetsCache then
        local list, maxSlots = func.loadPresets()       -- metadados leves
        local shots = func.getScreenshots(idsOf(list))  -- batch pesado
        presetsCache = merge(list, shots)
    end
    SendNUIMessage({ action = "open", presets = presetsCache })
end

-- save-through: server retorna o registro criado; atualiza cache local
RegisterNUICallback("save", function(data, cb)
    local ok, preset = func.saveOutfit(data.name, getCurrentClothing())
    if ok then
        presetsCache[preset.id] = preset   -- sem novo loadPresets()
    end
    cb({ success = ok, preset = preset })
end)
```

**Anti-padrões a flagar em audit:**

| Anti-padrão | Problema | Solução |
|-------------|----------|---------|
| Refresh rebusca tudo do server a cada interação | Queries + rede repetidas sem necessidade | Cache local + invalidação no CRUD |
| N+1 para enriquecer cada item (§1.4) | N queries + N respostas por abertura | Batch `getDetails(ids[])` |
| Lista carrega campos pesados (LONGTEXT/base64) | Resposta `tunnel_res` gigante (§1.6) | Lista = metadados; detalhe sob demanda |
| Dado gerável no client buscado do server | Round-trip + armazenamento desnecessários | Gerar localmente (screenshot do ped) |

### 2.1.2 Database writes — index, upsert, write-behind

§2.1 / §2.1.1 remove repeated **reads**. These rules cover the **write** side and the schema the queries run against. Examples use oxmysql's `MySQL.*` API (`server_script '@oxmysql/lib/MySQL.lua'`); the same calls exist as exports (`exports.oxmysql:prepare_async`, …).

**Rules:**

1. **Index what you filter by.** Every column in the `WHERE` / `JOIN` of a recurring query (identifier, passport, citizenid, plate, owner id) has an index, shipped in the resource's `.sql` next to the `CREATE TABLE`. Without it each call scans the whole table and gets slower as the table grows. oxmysql's `mysql_slow_query_warning` convar is the runtime signal; confirm with `EXPLAIN`.
2. **Upsert in one statement (D2).** `INSERT ... ON DUPLICATE KEY UPDATE` — never `SELECT` to decide between `INSERT` and `UPDATE` (two round-trips and a race between them). Requires a `PRIMARY` / `UNIQUE` key on the conflict column. Not `REPLACE INTO` (it deletes and re-inserts the row).
3. **Many rows = one round-trip (D2).** Several writes that belong together go in one `MySQL.transaction` — all commit or none do — not one `await` per row inside a loop.
4. **Write-behind only for data you can afford to lose (D1).** High-churn, low-value fields (playtime, last position, counters) are changed in memory, marked dirty and flushed on an interval, on `playerDropped` and on `onResourceStop`. **Money, items, ownership and anything a player paid for are written in the handler that changes them** — a crash between flushes loses everything still in memory.
5. **Do not double-write what the framework persists** (vRP datatable, QBCore/ESX player data, ox_inventory). Use the framework API and let it save.

```lua
-- WRONG: two round-trips and a race between them
local row = MySQL.single.await("SELECT 1 FROM player_stats WHERE passport = ?", { Passport })
if row then
    MySQL.update.await("UPDATE player_stats SET playtime = ? WHERE passport = ?", { playtime, Passport })
else
    MySQL.insert.await("INSERT INTO player_stats (passport, playtime) VALUES (?, ?)", { Passport, playtime })
end

-- CORRECT: one statement (passport is the PRIMARY KEY)
MySQL.prepare.await("INSERT INTO player_stats (passport, playtime) VALUES (?, ?) ON DUPLICATE KEY UPDATE playtime = ?", { Passport, playtime, playtime })
```

`MySQL.prepare` accepts only `?` placeholders (`??` and named placeholders throw).

```lua
-- WRONG: DB write on every tick of a per-player timer
MySQL.update("UPDATE player_stats SET playtime = playtime + 60 WHERE passport = ?", { Passport })

-- CORRECT: write-behind — memory is hot, DB is flushed in one transaction
local FLUSH_INTERVAL = 5 * 60 * 1000
local Playtime = {}   -- [Passport] = seconds
local Dirty = {}      -- [Passport] = true

local function flushPlaytime()
    local queries = {}
    for Passport in pairs(Dirty) do
        queries[#queries + 1] = {
            "INSERT INTO player_stats (passport, playtime) VALUES (?, ?) ON DUPLICATE KEY UPDATE playtime = ?",
            { Passport, Playtime[Passport], Playtime[Passport] }
        }
    end
    if #queries == 0 then return end
    Dirty = {}
    if not MySQL.transaction.await(queries) then
        print("^1[stats] playtime flush failed^7")
    end
end

CreateThread(function()
    while true do
        Wait(FLUSH_INTERVAL)
        flushPlaytime()
    end
end)

AddEventHandler("onResourceStop", function(resource)
    if resource == GetCurrentResourceName() then flushPlaytime() end
end)
```

The player-leave hook (`playerDropped`, or the framework's — vRP Creative `"Disconnect"`) calls the same flush and then clears that player's entry from `Playtime`, so the table does not grow with every player who ever joined.

| Anti-Pattern | Problem | Solution |
|--------------|---------|----------|
| Recurring `WHERE col = ?` on an unindexed column | Full table scan per call; degrades with table size | Index in the resource `.sql` |
| `SELECT` then `INSERT` / `UPDATE` | 2 round-trips + race | `ON DUPLICATE KEY UPDATE` |
| `for ... do MySQL.*.await(...) end` | N round-trips; handler suspended N times | One `MySQL.transaction` |
| `UPDATE` per tick / per movement / per small counter change | DB saturation under load | Write-behind (rule 4) |
| Write-behind for money / items / purchases | Loss or dupe on crash | Write in the mutating handler |
| Per-player memory table never cleared on leave | Grows for the whole uptime | Clear the entry in the leave hook |

**Audit grep hints:** `SELECT` immediately followed by `INSERT` / `UPDATE` on the same key; `MySQL.` / `oxmysql` calls inside `for` / `while`; `CREATE TABLE` without `KEY` / `INDEX` for columns used in the resource's `WHERE` clauses.

### 2.2 Pre-Build Client Sync Payloads (View Cache)

When server data lives in a raw cache (DB row shape) but must be normalized before sending to clients — `json.decode`, field renaming, counts, defaults — **build the client-facing shape once** when the cache is populated or updated. Do **not** rebuild on every `TriggerClientEvent`.

```lua
-- WRONG: transform on every send
TriggerClientEvent("manager:garageUpdated", source, buildManagerGarageListItem(id, cacheEntry))

-- CORRECT: send pre-built payload from view cache
TriggerClientEvent("manager:garageUpdated", source, ManagerGarageListCache[id])
```

**Pattern:** keep two layers — source cache (truth) and view cache (client-ready).

```lua
local GarageCache = {}              -- raw DB / source truth
local ManagerGarageListCache = {}   -- client-ready view (pre-built)

local function buildManagerGarageListItem(id, data)
    local permOut = data.perm or ""
    local ok, decoded = pcall(json.decode, permOut)
    if ok and decoded and type(decoded) == "table" and #decoded > 0 then
        permOut = decoded
    end

    local vehicleClassesOut = data.vehicleClasses or {}
    if not vehicleClassesOut or #vehicleClassesOut == 0 then
        vehicleClassesOut = {}
    end

    return {
        id = id,
        name = data.name,
        coords = data.coords,
        spawns = data.spawns or {},
        spawnCount = data.spawns and type(data.spawns) == "table" and _countTable(data.spawns) or 0,
        perm = permOut,
        type = data.type or "Normal",
        vehicleSet = NormalizeGarageVehicleSetId(data.vehicleSet or data.vehicle_set),
        vehicleClasses = vehicleClassesOut,
        requireService = data.requireService == true or data.require_service == 1,
    }
end

local function rebuildManagerGarageListItem(id)
    local data = GarageCache[id]
    if data then
        ManagerGarageListCache[id] = buildManagerGarageListItem(id, data)
    else
        ManagerGarageListCache[id] = nil
    end
end

local function rebuildManagerGarageList()
    ManagerGarageListCache = {}
    for id, data in pairs(GarageCache) do
        ManagerGarageListCache[id] = buildManagerGarageListItem(id, data)
    end
end

-- Resource start / DB load
loadGaragesFromDb()
rebuildManagerGarageList()

-- CRUD: rebuild view cache, then sync by audience
function upsertGarage(id, data, adminSource)
    GarageCache[id] = data
    rebuildManagerGarageListItem(id)
    -- Admin UI → source only (§1.6.1)
    TriggerClientEvent("manager:garageUpdated", adminSource, ManagerGarageListCache[id])
    -- World state → all players, small delta
    TriggerClientEvent("garages:updateGarage", -1, WorldViewCache[id])
end

function removeGarage(id, adminSource)
    GarageCache[id] = nil
    ManagerGarageListCache[id] = nil
    TriggerClientEvent("manager:garageDeleted", adminSource, id)
    TriggerClientEvent("garages:deleteGarage", -1, id)
end

-- Player bootstrap: one player, large payload → cerberus or pre-built chunks
exports["cerberus"]:SendFullSync(source, "garages:fullSync", SanitizedGarageCache, {
    key = "garages:bootstrap:" .. source,
    coords = GetEntityCoords(GetPlayerPed(source)),
    range = 150.0
})
```

If the client needs a sorted array, build that list once at bootstrap or full rebuild — not per player or per event:

```lua
local function buildManagerGarageList()
    local list = {}
    for id, item in pairs(ManagerGarageListCache) do
        list[#list + 1] = item
    end
    table.sort(list, function(a, b) return tostring(a.id) < tostring(b.id) end)
    return list
end
```

| Anti-Pattern | Problem | Solution |
|--------------|---------|----------|
| `build*(id, cacheEntry)` inside every `TriggerClientEvent` | Repeated decode/normalize/allocate on hot paths; CPU spikes when broadcasting | Rebuild view cache on load and on CRUD only |
| Full list sort on every delta sync | O(n log n) work per small change | Keep map cache; sort once for bootstrap or when list shape changes |
| Same transform in multiple handlers | Drift and inconsistent payloads | Single `build*` function; write only to view cache |
| Full resync (`Load*Player`, `Sanitize*Cache`, manual chunks) on single CRUD | Rebuilds entire cache + network blast for one change | Delta event or cerberus `SendDeltaSync`; full sync only from pre-built chunks |
| `Load*Cache()` full DB reload after one insert/update | O(all rows) query + reparse per admin action | Upsert affected entry in memory cache + rebuild view for that key |
| `Get*SummaryList()` / `build*List()` inside event handlers | Recompute + sort on every manager open | Cache summary/list at load/CRUD; handlers send cached reference |
| `TriggerClientEvent("manager:*", -1, ...)` | Admin payload to all clients | `source` for UI; `-1` only for world sync events (§1.6.1) |
| `TriggerClientEvent(-1, largeTable)` | Overflow / lag | cerberus `SendFullSync` / `SendDeltaSync` with scope |

### 2.2.1 Seeding client data — server-push bootstrap (canonical pattern)

Any resource whose clients need server data (points, blips, zones, garages, shops, props) uses **this lifecycle**. Do not invent another one — the server **pushes**, the client never **pulls** on start.

| Moment | Server does | Never |
|--------|-------------|-------|
| Resource start (server boot **or** `ensure`) | One `CreateThread`: DB → source cache → view cache (**built once**) → send to players already online. On server boot nobody is online, so it only builds the cache; on `ensure` it re-seeds everyone. | Build lazily on the first client request |
| Player connects | Framework player-loaded hook sends the **already-built** view to that `source` | DB query, rebuild view, `table.sort`, or re-chunk per player |
| CRUD (create / update / delete) | Update DB, patch `Cache[id]`, rebuild **only** `View[id]`, send a delta of that id | `Load*Cache()` full reload; full resync to everyone |
| Client start | Registers the receive handlers and waits | `CreateThread(Wait(N) → TriggerServerEvent("x:requestSync"))` |

**Player-loaded hook by framework:**

| Framework | Server hook | Target |
|-----------|-------------|--------|
| vRP Creative | `AddEventHandler("playerConnect", function(Passport, source)` | `source` |
| QBCore / Qbox | `AddEventHandler("QBCore:Server:PlayerLoaded", function(Player)` | `Player.PlayerData.source` |
| ESX | `AddEventHandler("esx:playerLoaded", function(playerId, xPlayer)` | `playerId` |
| Standalone | `AddEventHandler("playerJoining", function()` | `source` |

```lua
-- WRONG: every client pulls on start; every pull = SELECT * + rebuild + sort for ONE player
-- client
CreateThread(function()
	Wait(2000)
	TriggerServerEvent("service:requestSync")
end)
-- server
RegisterServerEvent("service:requestSync")
AddEventHandler("service:requestSync", function()
	LoadServicePoints()                                               -- full DB query per player
	TriggerClientEvent("service:syncFull", source, ListForClient())   -- decode + build + sort per player
end)
```

Why it is wrong: N players = N full queries + N identical payload builds; the endpoint is client-callable, so a cheat loop on `requestSync` becomes a DB/CPU flood (§5.1, Pass 2b E-a); the reload races with CRUD; `Wait(2000)` is a guess, not a signal.

```lua
-- CORRECT: build once at start, push on connect, patch one index on CRUD
local Loaded = false
local Cache = {}     -- DB rows, keyed by tostring(id)
local View = {}      -- client-ready payload, keyed by tostring(id) — built at start / on CRUD only
local Chunks = nil   -- View split for bootstrap; nil = re-split on next send

local function BuildView(row)
	return {
		id = row.id,
		name = row.name,
		coords = json.decode(row.coords or "[]") or {},
		distance = tonumber(row.distance) or 1.0,
	}
end

local function SendSeed(target)
	if not Chunks then
		Chunks = {}
		local current, count = {}, 0
		for key, item in pairs(View) do
			current[key] = item
			count = count + 1
			if count >= CHUNK_SIZE then
				Chunks[#Chunks + 1] = current
				current, count = {}, 0
			end
		end
		if count > 0 or #Chunks == 0 then Chunks[#Chunks + 1] = current end
	end

	local targets = target == -1 and GetPlayers() or { target }
	for _, src in ipairs(targets) do
		for i, chunk in ipairs(Chunks) do
			TriggerClientEvent("service:seedChunk", tonumber(src), chunk, i == #Chunks)
			Wait(CHUNK_DELAY)
		end
	end
end

CreateThread(function()
	Wait(3000) -- let oxmysql / framework finish starting
	for _, row in ipairs(exports["oxmysql"]:querySync("SELECT * FROM service_points") or {}) do
		local key = tostring(row.id)
		Cache[key] = row
		View[key] = BuildView(row)
	end
	Loaded = true
	SendSeed(-1) -- server boot: no players, nothing sent; ensure: re-seeds everyone online
end)

AddEventHandler("playerConnect", function(Passport, source)
	if Loaded then SendSeed(source) end -- if not loaded yet, the start thread covers this player
end)

-- CRUD (after the DB write succeeds): one index, one delta
Cache[key] = row
View[key] = BuildView(row)
Chunks = nil
TriggerClientEvent("service:upsert", -1, View[key])

-- delete
Cache[key], View[key], Chunks = nil, nil, nil
TriggerClientEvent("service:remove", -1, key)
```

```lua
-- client: only receives; no request on start
local Points = {}

RegisterNetEvent("service:seedChunk", function(chunk, isLast)
	for key, item in pairs(chunk) do Points[key] = item end
	if isLast then RefreshPoints() end
end)

RegisterNetEvent("service:upsert", function(item) Points[tostring(item.id)] = item end)
RegisterNetEvent("service:remove", function(key) Points[key] = nil end)
```

**Transport choice (same lifecycle in all cases):**

1. **Small view** (whole payload < ~8 KB) → one `TriggerClientEvent("x:seed", target, View)`; no chunking.
2. **Large view, cerberus ensured in the project** → `exports["cerberus"]:SendFullSync(target, "x:seed", View, { key = "x:seed" })` instead of the chunk loop.
3. **Large view, no cerberus** → pre-built chunks + `Wait(CHUNK_DELAY)` as above. Chunks are split **once** and reused for every player until a CRUD clears them.

Keys are `tostring(id)` so the msgpack payload stays a map (sparse integer keys can serialize unpredictably).

| Anti-Pattern | Problem | Solution |
|--------------|---------|----------|
| Client `CreateThread` + `Wait` + `TriggerServerEvent("*:request*")` to get initial data | N pulls, spam-able endpoint, guessed timing | Server push: start thread + player-loaded hook |
| `Load*Cache()` / `SELECT *` inside a player request or connect | Full DB query per player | Load once at resource start |
| `ListForClient()` / `build*List()` / `table.sort` inside the send function | Same payload rebuilt for every player | View built at start; CRUD patches one key |
| Re-sanitize / re-chunk inside the per-player loop | O(players × rows) work | Split chunks once; clear only on CRUD |
| Full resync to everyone after one CRUD | Network blast for one change | Delta event of `View[key]` |

### 2.3–2.5 Audit passes

The audit checklist (view-cache steps, Pass 0–7, matrices V-a…V-k, E-a…E-g, N-a…N-d, report gates) lives in [audit-passes.md](audit-passes.md) — read it only for `/fxmind audit`. Section numbers are unchanged.

---

## 4. Cerberus (modular resource)

[`cerberus`](https://github.com/proelias7/cerberus) is a modular FiveM resource. The public README highlights **Load Balance**; the full module also includes **SafeEvent** (server anti-exploit) and **SetCooldown** (client rate-limit) when enabled in `config/config.lua`:

```lua
config.modules = {
    banned = false,
    safeEvent = true,
    analytics = true,
}
```

### 4.1 Network sync (Load Balance)

[`cerberus`](https://github.com/proelias7/cerberus) centralizes large server→client payload delivery. Consumer scripts prepare the payload and call an export; cerberus handles transport, chunking, queue, priority, and client-side reassembly.

**Flow:**

```text
resource server -> cerberus server -> network -> cerberus client -> local TriggerEvent -> resource client
```

The final `TriggerEvent` on the client is local and does not add extra network traffic.

### 4.2 When to use cerberus vs `TriggerClientEvent`

| Situation | Target | Method |
|-----------|--------|--------|
| Reply to one player (UI, admin panel) | `source` | `TriggerClientEvent` with pre-built cache |
| Initial data for a player (bootstrap) | `source` from player-loaded hook | Server push of pre-built view (§2.2.1) — never a client request |
| Small world delta to **all** (id, coords, delete) | `-1` | `TriggerClientEvent` if payload < ~8 KB |
| Small world delta with flood protection | `-1` | `SendDeltaSync(-1, event, payload)` |
| Full/large cache to **one** player | `source` | `SendFullSync(source, ...)` |
| Full/large cache to **many** or **scoped area** | `-1` or table | `SendFullSync` / `SendDeltaSync` + `coords`, `range`, `scopeRadius` |
| Chunk loop to players | — | cerberus when ensured; otherwise chunks split once from the view cache (§2.2.1) |

> **Rule:** `-1` = global **gameplay** sync with **small** payload. Admin/manager events → **`source` only** (§1.6.1).
>
> **Rule:** When the project ensures cerberus, use its exports instead of a chunk loop. Without cerberus, use the §2.2.1 chunk pattern (split once, reuse for every player, `Wait` between chunks).
>
> **Rule:** Prefer `SendDeltaSync` for unit updates. Reserve `SendFullSync` for bootstrap or full cache rebuild.

> **Rule (N1/N4):** never loop `vRP.Players()` with `TriggerClientEvent` + `Wait` (blocks the server thread, O(n) events). Full rebuild → `SendFullSync(-1, event, payload, { key = ... })`; unit update → `SendDeltaSync(-1, event, delta)`. When cerberus is in the project, name the export in the fix — not a vague "use -1" or a statebag (statebags carry small flags, not payload tables).

```lua
-- WRONG
for _, src in pairs(vRP.Players()) do TriggerClientEvent("robberys:updateBlips", src, payload) Wait(30) end
-- CORRECT
exports["cerberus"]:SendDeltaSync(-1, "robberys:updateBlips", delta)
```

### 4.5 Load balance — what to avoid

- Manual chunking when cerberus is ensured, or chunking rebuilt per player (§2.2.1)
- Full sync for every small change
- Putting queue/priority logic in the consumer client
