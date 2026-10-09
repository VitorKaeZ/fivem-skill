# FiveM Best Practices

**Author:** Elias Araújo  
**Focus:** Performance, Optimization, and Security (framework-agnostic)

> **Split index** — one Cursor skill (`fivem-development`), multiple reference files loaded on demand.  
> Section numbers (`§1.6.1`, `§2.4`, `§5.1`, …) stay stable across files.

| File | Contents | Corrections category |
|------|----------|----------------------|
| [communication.md](communication.md) | §1.1–§1.3 · §1.7 Tunnel/events/`_`/same-side/response budget | `communication` |
| [performance.md](performance.md) | §1.4–§1.6.3 loops/sleep/**§1.5.1 distance + split threads**/payloads/**tunnel_res**/broadcast/StateBags (**§1.6.3 change handlers**) · §2.1–§2.2 cache/**§2.1.1 client cache**/**§2.1.2 DB writes**/view cache · §4.1–4.2 · §4.5 | `performance` |
| [audit-passes.md](audit-passes.md) | §2.3–§2.5 audit only: Pass 0–7, V-a…V-k, E-a…E-g, N-a…N-d, report gates · **§2.6 measurement** (resmon / profiler) | `performance` |
| [architecture.md](architecture.md) | §3.5–3.6 · §3.8 monolith, reuse, state placement · **§3.13 server-owned entities** | `architecture` |
| [style.md](style.md) | §3.1–3.4 · §3.7 · §3.9–**§3.11** tables, comments, local-function extract, checklist | `style` |
| [security.md](security.md) | §4.6–4.8 SafeEvent/SetCooldown · §5 server auth/**§5.3 input validation** | `security` |
| [api.md](api.md) | §4.3–4.4 cerberus exports & examples | `api` |
| [quality-gates.md](quality-gates.md) | **Definition of Done** for task mode — checklist by artifact + self-review loop | `quality` |

## Quick load (agents)

| Need | Read |
|------|------|
| Tunnel vs events, `_` prefix, response budget | [communication.md](communication.md) |
| Dynamic sleep, loops, distance checks §1.5.1, payloads, tunnel_res, broadcast §1.6.1, StateBags §1.6.2 (cost) / §1.6.3 (handlers), cache, client cache §2.1.1, DB writes §2.1.2 | [performance.md](performance.md) |
| Audit passes §2.3–§2.5, measurement §2.6 | [audit-passes.md](audit-passes.md) |
| New resource / monolith / globals §3.5–3.6, spawning shared entities §3.13 | [architecture.md](architecture.md) |
| Comments, lookup tables, single-use helpers §3.11, anti-patterns | [style.md](style.md) |
| SafeEvent, endpoint auth §5.1, server resolution §5.2, input validation §5.3 | [security.md](security.md) |
| cerberus `SendFullSync` / export signatures | [api.md](api.md) |
| **Implement / refactor code (task mode)** | [quality-gates.md](quality-gates.md) |
| **NUI CEF overlay / Vite hash (task + audit Pass NUI)** | [fivem-react-nui/ui-guide.md](../fivem-react-nui/ui-guide.md) §2, §6 |
| Full audit | communication §1.1 + performance (§1.6.1, §2.1.1) + audit-passes (§2.3–§2.5, Pass NUI) + architecture §3.6 + security §5.1 + §5.3 |

Router: [SKILL.md](SKILL.md)

