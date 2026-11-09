# Ordered Region Failover for Signal Shards in HAProxy

*   **Author:** Aaron van Meerten
*   **Status:** Draft
*   **Date:** 2026-11-05

--------------------------------------------------------------------------------

## Overview

The HAProxy config for signal shards fails a region over to 1 shard of the next region at a time. It does not use all of its shards.
This design adds 3 HAProxy backends for each release, 1 for each step in the failover order. Each step is a tier.

When every home-region shard of a release is unusable, new rooms spread over all shards of the next 2 regions.
When those are also unusable, new rooms spread over all shards of every other region.
The region order comes from `haproxy_regions_by_region` in `config/vars.yml`.
Existing meetings stay on their shard, in every region.

The change is mainly in `ansible/roles/hcv-haproxy-configure/templates/haproxy.cfg.template.j2`.
`ansible/configure-haproxy-local.yml` adds the switch map to consul-template.

It ships in phases. First, a separate change makes HAProxy keep agent state across a reload.
Then the tier backends and rules ship with the switch off.
Last, a Consul key in each region turns the switch on.

The design needs no change to signal-sidecar.
A separate signal-sidecar change adds a prosody CPU drain at 80%.
That change ships only after this change runs in production.
The CPU drain drains home shards more often. Without tiers, each drain sends the region's new rooms to 1 shard.
The CPU drain design sets its own ship conditions and its off switch.

The users are the people in meetings during a regional overload, and the on-call engineers.

### Glossary

| Term | Meaning |
|---|---|
| Shard | 1 signal node: prosody, jicofo, and signal-sidecar on 1 host. This document drops the `prod-8x8-` prefix. |
| Region | An OCI region, for example ap-mumbai-1. The template calls `<env>-<region>` a datacenter. This document uses "region" only. |
| Home region | The region of the HAProxy that receives the request. |
| Release | A set of shards with the same `release_number` in Consul. The live release comes from the Consul key `releases/<env>/live` and the live map. |
| Release backend | The existing backend `release-N`. It lists home-region shards of release N as active servers, and every other passing shard as `backup`. |
| Tier | 1 step in the failover order for 1 release. Tier 1 is the home region. Tier 2 is the next 2 regions in `haproxy_regions_by_region`. Tier 3 is every other region. |
| Tier backend | A new backend for 1 tier, for example `release-7068-t2`. It lists every passing shard of every release. Only the shards of its release in its regions have a weight above 0. |
| Stick token | The `X-StickToken` header. HAProxy sets it to `X-Group` plus `X-Room`, the room name. HAProxy stores it in the shared `nodes` table and uses it to send the next request of a meeting to the same shard. A stick match needs `X-Room`. A stick store also needs `X-StickTokenFlag`, which HAProxy sets for non-web requests. Peers copy every write to every HAProxy. Tier backends copy these lines unchanged. |
| Tenant pin | A map from tenant to release, in `tenant.map`. See README_HAPROXY.md, "tenant pinning". `?release=release-<n>` in the URL overrides the pin for 1 request. |
| Agent check | HAProxy asks signal-sidecar on TCP port 6060 every 10 seconds. The reply sets UP or DOWN, ready or drain, and a weight percent. |
| Drain | Agent reply `drain`. The server takes no new load-balanced traffic, but HAProxy still sends stick matches to it. |
| DOWN | Agent reply `down`. The server takes no traffic, and stick matches to it fail. |
| Usable server | A server that is UP, not drained, and has a weight above 0. |
| `nbsrv` | HAProxy fetch that returns the number of usable servers in a backend. |

## The Problem

On 2026-11-04, both live-release shards in ap-mumbai-1 became unusable at 06:05 UTC.
The ap-mumbai-1 HAProxy then sent every new ap-mumbai-1 room to 1 shard, eu-frankfurt-1-s12.
That shard reached about 30 sessions per second and went DOWN at 06:07.
The other eu-frankfurt-1 shards, s14 and s28, stayed near 0.1 sessions per second.

Prosody on s8, s27, and s12 reached 100% CPU. The ap-mumbai-1 shards also reached 100% on 2026-11-03.
The data comes from the Grafana dashboard `jitsi-oci-hosts-prod-01-oci-metrics`.

The cause is the layout of the release backend.
The release backend has `no option allbackups`, so HAProxy uses only the first usable backup.
When that backup fails, the next backup gets all the new rooms.

The template writes the backups in region order, from `haproxy_regions_by_region`.
Inside 1 region, the order comes from consul-template. Nobody chose that order. For example, `s100` sorts before `s12`.

So a failover overloads 1 remote shard at a time.
That shard can then fail, and each failure moves every meeting on it.

This design does not add capacity.
The live release had only 2 shards in ap-mumbai-1, and they ran at 100% CPU.
A spread over the next region lowers the peak load per shard, but the total load stays the same.
If the next region is also near its limit, the overflow moves on to the region after it.

## Goals

1.  If no home-region shard of the live release is usable, HAProxy spreads new rooms over the usable shards of the next 2 regions.
    In lab test 4, 1 HAProxy holds 1000 new rooms open. The busiest shard of the tier holds at most 1.5 times the mean.
    `hash-balance-factor 150` sets this bound.
2.  HAProxy sends new rooms to tier k+1 only when tier k has `nbsrv` 0.
3.  If tier 2 has no usable server, HAProxy spreads new rooms over the usable shards of every other region.
4.  Existing meetings stay on their shard while the shard is UP and its stick entry exists.
    This includes cross-region meetings and meetings on shards of other releases.
5.  For new rooms, HAProxy uses shards of other releases only when no region of the release has a usable server.
6.  Every release gets tier backends, canary releases included.
    If no tier of a pinned release has a usable server, new rooms use the tiers of the live release.
7.  A Consul key in each region turns the tier rules on and off with no reload. A new HAProxy reads the current value.
8.  On-call gets a page when an HAProxy has 0 UP servers in every `release-N` backend.
9.  Metrics show sessions per tier backend, so a failover to tier 2 or tier 3 is visible.
10. After a region turns the switch on, its `www-http` 5xx ratio for 24 hours is at most 1.5 times the 24 hours before.
    Lab test 9 counts split rooms.

## Non-Goals

*   Any change to signal-sidecar. The prosody CPU drain is a separate change.
*   Agent state across reloads as part of the tier change. It ships first, as a separate change. This design depends on it (section 4).
*   A change to the `release-N` backends or to the `nbsrv` check of the tenant pin rule.
*   A maintenance response for `xmpp-websocket`, a user-facing 503 page, or a client change. These are separate follow-up work.
*   Changes to shard-specific backends and paths. They use `no-check` and ignore drain.
*   Changes to the size or expiry of the stick table.
*   More shards in ap-mumbai-1, or any other capacity change.
*   An order inside tier 2 or tier 3. Every weight-256 shard in 1 tier gets the same weight.

## Open Questions

*   **Unverified HAProxy behavior**: The design depends on 4 claims from the HAProxy 2.8 source. No lab test confirms them yet.
    *   `nbsrv` returns 1 when no active server is usable but a backup is usable.
    *   A weight-0 server that uses `track` follows the UP and DOWN state of an agent-checked server.
    *   A stick match reaches an UP server at weight 0.
    *   An agent `down` reply uses the `fall` counter.
*   **Server-state file**: A lab test must show that agent drain and weight survive a reload with `load-server-state-from-file`. This test is the gate of Phase 1.
*   **Width of tier 2**: The next 2 or the next 3 regions. `haproxy_tier_2_region_count` sets it, and the default is 2.
*   **Metric cardinality**: telegraf and the Prometheus exporter on port 8405 collect metrics for every server line.
    Tier backends multiply the server lines by about 4: 3 tier backends plus `release-N`. The lab must count the series before production.
*   **Failover budget**: The concept asks for a budget of tier failovers per region per hour, but gives no number. A recording rule waits for this number.

## Critical User Journeys (CUJs)

### CUJ 1: Home region fails over to the next region

*   **Given**: The tier switch is on. Both live-release shards in ap-mumbai-1 are drained or DOWN. eu-frankfurt-1 has 3 usable live-release shards, and uk-london-1 has 2.
*   **When**: A user in India opens a new room. The request reaches the ap-mumbai-1 HAProxy.
*   **Then**: HAProxy uses `release-7068-t2`, which holds eu-frankfurt-1 and uk-london-1. The room hashes to 1 of the 5 shards. Other new rooms spread over all 5.

### CUJ 2: An existing meeting stays on a drained shard

*   **Given**: A meeting runs on ap-mumbai-1-s8. Its stick entry is in the `nodes` table. Then s8 drains.
*   **When**: A new participant joins the meeting through the ap-mumbai-1 HAProxy.
*   **Then**: HAProxy uses tier 2, because tier 1 has `nbsrv` 0. The tier-2 backend lists s8 at weight 0. The stick match sends the participant to s8.

### CUJ 3: A cross-region meeting stays on its shard

*   **Given**: A meeting started in Germany runs on eu-frankfurt-1-s12. ap-mumbai-1 has usable shards.
*   **When**: A participant in India joins through the ap-mumbai-1 HAProxy.
*   **Then**: HAProxy uses tier 1. The tier-1 backend lists s12 at weight 0. The stick match sends the participant to s12.

### CUJ 4: A pinned tenant fails over inside its release

*   **Given**: Tenant `acme` is pinned to `release-7070`. Every ap-mumbai-1 shard of release 7070 is drained. eu-frankfurt-1 has usable shards of release 7070.
*   **When**: A user of `acme` opens a new room through the ap-mumbai-1 HAProxy.
*   **Then**: HAProxy uses `release-7070-t2`, not the live release.

### CUJ 5: On-call turns the tiers off

*   **Given**: The tier switch is on. 503 responses or 5xx in tier backends rise, or users report split rooms.
*   **When**: On-call sets the Consul key `haproxy/<env>/tiers` to `off` in 1 region, or in every region.
*   **Then**: consul-template writes the map, and `update-haproxy-map.sh` loads it with no reload. New requests use today's rules. The value stays `off` after a reload and on a new HAProxy.

### CUJ 6: A pinned release with no usable shard uses the live tiers

*   **Given**: The tier switch is on. Tenant `acme` is pinned to `release-7070`. No shard of release 7070 is usable in any region.
*   **When**: A user of `acme` opens a new room through the ap-mumbai-1 HAProxy.
*   **Then**: HAProxy uses `release-7068-t1`, the tier 1 backend of the live release. New rooms spread over the live-release shards of ap-mumbai-1.

## Technical Plan (Architecture)

All changes are in the `hcv-haproxy-configure` role and in `ansible/configure-haproxy-local.yml`, except the alert rules.
The template has 2 render stages.
Ansible (Jinja) knows the region order of this HAProxy.
consul-template knows the releases and the shards.

### 1. Tier backends

consul-template writes 3 tier backends for each release R. The name is `release-R-tk`, for example `release-7068-t2`.
Jinja splits this HAProxy's region order, `ns.haproxy_datacenters`, into the 3 tiers:

*   Tier 1 is the first region, the home region.
*   Tier 2 is the next `haproxy_tier_2_region_count` regions, 2 by default.
*   Tier 3 is every other region. If no region is left, the template writes no tier 3.

For ap-mumbai-1, tier 2 is eu-frankfurt-1 and uk-london-1. Tier 3 is the other 6 regions.
So 1 tier name holds different regions on HAProxies in different regions.
`haproxy_regions` is `haproxy_regions_by_region[haproxy_region]`, or `default_regions` if that entry is missing.
The template keeps only regions in `consul_wan_regions_oracle`.
`release-N` uses the same list today, so shards of a region outside it get no server line in either backend.

Each tier backend copies the `default-server`, balance, and stick lines of `release-N`.
The `default-server` line sets `inter`, `fall`, and `rise` from the role defaults.
The other lines are `balance hdr(X-StickToken)`, `hash-type consistent`, `hash-balance-factor 150`, and `stick match` and `stick store-request` on the `nodes` table.
The same `fall` and `rise` values make both backends change a shard's state after the same number of checks.
The `nodes` table uses `srvkey addr`, so a stick match finds a server by address and port in any backend.

Each tier backend lists every Consul-passing shard of every release, in 2 kinds of server lines:

| Server | Which shards | Line |
|---|---|---|
| `R-<shard>` | Shards of release R in the regions of tier k | `weight 256`, `agent-check` on the signal-sidecar agent port, as in `release-N` today |
| `R-fallback-<shard>` | Every other passing shard | `weight 0`, `track release-R'-tj/R'-<shard>`, where R' is that shard's release and j is the tier of its region |

Rules for both kinds:

*   No server is `backup`. So `nbsrv` counts only the weight-256 shards that are UP and not drained.
*   Each server keeps the `id` of today, `shard_id + 10`. Same ids give the same positions on the hash ring as the active list of `release-N`.
*   The server names keep the `<release>-` and `<release>-fallback-` forms. The `Shard_HTTP_5xx_Elevated` alert parses these names.
*   A weight-0 server takes no load-balanced traffic. HAProxy still sends a stick match to it if it is UP. A drained server works the same way.
*   Each shard has exactly 1 agent-checked line in the tier backends, in its own release and the tier of its region. All other copies track that line.
    So each HAProxy sends 1 more agent check to each shard than today, not 4 times more.

### 2. Routing rules

The frontend sets 1 new variable before the `use_backend` rules:

*   `req.route_release` is the tenant pin when the pin's `release-N` has `nbsrv` above 0. Otherwise it is the live release.
    The tenant pin includes `?release=`, as today.
*   `req.tiers_on` is the value of the `tiers` key in the new switch map. A missing key means `off`.

consul-template writes 1 rule for each release R and each tier k, after the shard-specific rules and before the pin rule:

```
use_backend release-R-tk if { var(req.tiers_on) -m str on } { var(req.route_release) -m str release-R } { nbsrv(release-R-tk) gt 0 }
```

After these rules, consul-template writes a second set for the live release.
Each rule in this set checks `req.live_backend`, the live release from `live.map`:

```
use_backend release-R-tk if { var(req.tiers_on) -m str on } { var(req.live_backend) -m str release-R } { var(req.route_release) -m reg ^release-[0-9]+$ } { nbsrv(release-R-tk) gt 0 }
```

This set catches a pinned release when no tier of that release has a usable server.
Without it, the pin rule sends the request to `release-<pin>`, which lists live-release shards as backups.
That puts every new room on 1 live-release shard, the failure of 2026-11-04.
The live tiers spread the same rooms over the live release, in the same region order.
The regex check keeps `?release=<shard>` on the pin rule, so a direct shard override still works.

Every backend name in these rules is static, so `haproxy -c` rejects a missing backend.
The rules for 1 release follow its tier order. For 3 releases and 3 tiers, that is 18 rules: 9 in each set.
HAProxy stops at the first false condition, so most rules cost 1 string compare.

The pin rule and the live rule stay as they are, after the tier rules.
They catch a request when every tier of its release and of the live release has `nbsrv` 0, or when the switch is off.
Then `release-N` falls back to other releases through its backup chain, as today.

```text
request
  |
  +-- shard path or X-Room ends in _<shard> --> shard backend          (unchanged)
  |
  +-- tiers on AND route_release = R:
  |      nbsrv(release-R-t1) > 0 --> tier 1: hash over home shards of R
  |      nbsrv(release-R-t2) > 0 --> tier 2: hash over shards of R in the next 2 regions
  |      nbsrv(release-R-t3) > 0 --> tier 3: hash over shards of R in every other region
  |
  +-- tiers on AND route_release is release-<n> AND live release = L:
  |      nbsrv(release-L-t1) > 0 --> tier 1 of the live release
  |      ...                     --> through tier 3
  |
  +-- pin has servers --> release-<pin>                                (unchanged)
  +-- otherwise       --> release-<live>                               (unchanged, other releases as backup)

inside any tier backend:
  stick match to an UP server, any weight --> that shard
  no match --> consistent hash over the weight-256 shards of the tier
```

A GA switch changes `live.map` at once through the admin socket.
`req.route_release` reads that map, so the tier rules follow the switch with no reload.
If the new live release has no rendered rules yet, requests fall through to the live rule, as today.

### 3. Runtime switch

A new map file `/etc/haproxy/maps/tiers.map` holds 1 line, `tiers on` or `tiers off`.
It works like `live.map` and `tenant.map`:

*   The Consul key `haproxy/<env>/tiers` holds the value. Consul KV is separate in each region, so each region has its own switch.
*   consul-template renders `tiers.map.template` to the map file. The file gets `tiers on` only if the key is exactly `on`. A missing key or any other value gives `tiers off`.
*   The template command runs `update-haproxy-map.sh`, which loads the map through the admin socket with no reload.
*   A reload and a new HAProxy both read the file. So every HAProxy in a region follows the key, also after a recycle.

On-call sets the switch for 1 region with `consul kv put -datacenter=<env>-<region> haproxy/<env>/tiers on`.
To set all regions, on-call runs that command once for each region.

To test 1 HAProxy, send `set map /etc/haproxy/maps/tiers.map tiers on` to its admin socket.
That value lasts only until the next reload or the next render of the map. Then the HAProxy reads the file again.
If Consul is down, this `set map` is the only way to change the switch.

### 4. Prerequisite: agent state across reloads

This part ships as a separate change, before the tier backends (Phase 1 of the implementation plan).
It applies to every backend through `defaults global_defaults`, `release-N` included. The tier switch does not control it.

`ExecReload` in `haproxy.service.j2` already writes `show servers state` to `haproxy_state_file` before each reload.
The config never reads that file. The change adds `server-state-file` to `global` and `load-server-state-from-file global` to `defaults global_defaults`.
If lab test 8 confirms it, servers keep their drain state and agent weight after a reload. They do not start at UP and weight 256.

Without this, every drained home shard counts in `nbsrv` for up to 10 seconds after each reload.
Reloads follow every change in Consul passing state in any of 9 regions, so they are likely during an incident.

`haproxy-configurator-payload.sh` drains the HAProxy from the OCI load balancer before the reload, and undrains it after.
This gives the stick table time to fill from the local peer before traffic returns.
The state file adds agent state to that protection.

After a crash, systemd still runs `ExecStop`. socat cannot reach the socket of the dead process, so the shell redirect empties the file.
HAProxy then starts with no saved state, as it does today. The agent check sets each server within 1 agent interval, 10 seconds.
Lab test 8 also checks that HAProxy starts with an empty state file.

### 5. Telemetry and alerts

*   The Prometheus exporter already gives `haproxy_backend_active_servers` and `haproxy_backend_sessions_total` for each backend.
    Tier names carry the tier and the region, so no new HAProxy counter is necessary.
*   New alert rules in infra-provisioning `nomad/prometheus.hcl`:
    *   Warn when sessions flow into a tier-2 or later backend. This means that a region failed over.
    *   Page when an HAProxy has 0 active and 0 backup servers in all `release-N` backends. Then HAProxy returns 503.

### 6. What does not change

*   The `release-N` backends, the pin rule, the live rule, and the `nodes` backend.
*   Shard-specific and standalone backends.
*   The stick table: its key, size, expiry, and peers.
*   signal-sidecar and its agent replies.

## Risks

*   **Return wave**: When 1 drained home shard returns, `nbsrv` of tier 1 becomes 1. Every new room of the region then goes to it.
    Today the same shard gets the same wave. On 2026-11-04, s27 changed state 4 times in 6 minutes.
    Exit hysteresis in signal-sidecar is the fix, and it is not part of this design.
    Accepted: today has the same wave, and the CPU drain design owns the hysteresis fix.
*   **Split rooms**: Each HAProxy reads agent state on its own 10-second timer.
    During a drain change, 2 first joiners of 1 new room can land in 2 regions.
    Accepted: today has the same timers. Lab test 9 measures the rate before Phase 5.
*   **Mixed fleet**: During rollout, HAProxies with the switch on and off route new rooms differently. This happens only when tier 1 is empty.
    Accepted: it lasts only during Phase 5, and existing meetings keep their shard.
*   **Hard outage**: If an agent does not answer, HAProxy keeps the last state of that server.
    Failover then waits for Consul to fail the shard, a render, and a reload. `release-N` has the same delay today.
    Accepted: the tier change does not make it worse.
*   **Config size**: The server lines grow by about 4 times.
    The lab and stage-8x8 must measure render time, `haproxy -c` time, and reload time.

## Alternatives Considered

### Alternative A: `option allbackups` in the release backends

*   **Pros**: 1-line change. New rooms spread over all backups, not 1.
*   **Cons**: HAProxy uses every backup region at the same time. ap-mumbai-1 can then fail over to us-phoenix-1 before eu-frankfurt-1 or ap-tokyo-1. It also spreads pinned and canary traffic over other releases at the same time. Template line 346 sets `no option allbackups` so that fallback stays by release.
*   **Reason for Rejection**: Rejected by author: it ignores the region order in `haproxy_regions_by_region`.

### Alternative B: Tier backends that list only the shards of their region

*   **Pros**: Smaller backends. No weight-0 copies and no `track` lines.
*   **Cons**: A stick entry that points to a shard outside the backend finds no server. HAProxy hashes the request again, and the meeting moves.
*   **Reason for Rejection**: Rejected by author: cross-region meetings and meetings on other releases would break.

### Alternative C: Change `release-N` in place

*   **Pros**: No new backends. Fewer server lines.
*   **Cons**: The pin rule checks `nbsrv` of `release-N`, and today that count includes the first usable backup. Without backups, the check fails when the pinned release's home shards drain. The tenant then moves to the live release. (Lab test 1 checks the count.)
*   **Reason for Rejection**: Rejected by author: release pins depend on `nbsrv` of `release-N` with backups.

### Alternative D: Dynamic tier backend names

*   **Pros**: 1 rule per tier serves every release. The rules follow `live.map` at once.
*   **Cons**: A wrong or missing name makes `nbsrv` return 0, and HAProxy skips the tier with no error. `haproxy -c` cannot check a name that is built at request time.
*   **Reason for Rejection**: Rejected by author: the failure is silent. Static rules for all releases also follow `live.map`, and `haproxy -c` checks them.

### Alternative E: Static tier rules for the live release only

*   **Pros**: Fewest rules, 1 per tier. `haproxy -c` checks every name.
*   **Cons**: consul-template writes the live release into the rules. The reload comes at least 60 seconds after a GA switch. Then it waits for the `haproxy_configurator_lock` Consul lock. Until then, new rooms go to the old release's tiers. Pinned and canary traffic get no tiers.
*   **Reason for Rejection**: Rejected by author: the rules lag a GA switch, and pinned releases get no failover order.

### Alternative F: Tiers for live traffic only

*   **Pros**: Pinned routing stays exactly as today. A smaller lab test matrix.
*   **Cons**: A pinned tenant whose home shards drain still fails over to 1 backup shard at a time. This is the failure of 2026-11-04.
*   **Reason for Rejection**: Rejected by author: every release must get the same failover order, and canary releases can become live.

### Alternative G: 1 tier for each region, in strict order

*   **Pros**: Overflow follows `haproxy_regions_by_region` exactly. ap-mumbai-1 fills eu-frankfurt-1 before uk-london-1.
*   **Cons**: Up to 9 tier backends per release. The server lines grow by about 10 times, and there are 54 rules for 3 releases. 1 remote region takes all the overflow until it fails.
*   **Reason for Rejection**: Rejected by author: the cost is about 2.5 times that of 3 tiers. A tier of 2 regions spreads the overflow wider.

### Alternative G2: 2 tiers, the home region and then every other region

*   **Pros**: The fewest backends: 2 per release. The widest spread at the first failover.
*   **Cons**: It drops the region order. ap-mumbai-1 sends as many new rooms to sa-saopaulo-1 as to eu-frankfurt-1.
*   **Reason for Rejection**: Rejected by author: the next regions in the order are the nearest, and tier 2 keeps them first.

### Alternative H: Rotate the `release-N` template for each tier, with other regions as `backup`

*   **Pros**: 1 template loop. Every tier backend holds every shard.
*   **Cons**: `nbsrv` counts a usable backup, so a tier backend never reports 0. Each tier needs a separate probe backend to count its active servers. (Lab test 1 checks the count.)
*   **Reason for Rejection**: Rejected by author: it doubles the backends and gives the same routing as the chosen design.

### Alternative I: Region backends plus `in_table` routing of stuck rooms to `release-N`

*   **Pros**: Small change to the order of the rules.
*   **Cons**: `in_table` does not check the state of the server. A stuck room on a DOWN shard goes to `release-N` and then to the 1-shard backup chain.
*   **Reason for Rejection**: Rejected by author: it keeps the 1-shard chain for rooms on failed shards.

### Alternative J: More shards in ap-mumbai-1

*   **Pros**: A routine release change. No HAProxy change.
*   **Cons**: It does not fix the 1-shard failover. Any region with few shards can fail the same way.
*   **Reason for Rejection**: Rejected by author: it does not replace this design. It is a capacity change and can still happen separately.

### Alternative K: Fail over when tier k has fewer than N usable shards

*   **Pros**: 1 surviving shard does not take every new room.
*   **Cons**: N depends on the shard count of each region, which changes at each scale event. A wrong N fails a healthy region over.
*   **Reason for Rejection**: Rejected by author: `gt 0` is 1 constant in each rule, so a later change can raise it. Tier 2 already spreads overflow wide.

--------------------------------------------------------------------------------

## Non-Functional Requirements

*   **Rollout**: The Detailed Implementation Plan gives the phases and the gate of each phase. These are the switch steps:
    1.  Deploy Phase 3 with no Consul key. The switch is `off`, so no rule sends traffic to the tier backends.
    2.  On 1 stage-8x8 HAProxy, check `show stat` and `nbsrv` of each tier backend.
    3.  Test 1 stage-8x8 HAProxy with `set map`. Then set the key `on` in 1 stage-8x8 region.
    4.  Set the key `on` in ap-mumbai-1, then in each other region.
    5.  Existing meetings keep their shard in a mixed fleet, because the stick-table key and `srvkey addr` do not change.
*   **Rollback**:
    1.  If the signal-sidecar CPU drain is on in the region, turn it off. With tiers off, each CPU drain sends new rooms to 1 shard.
    2.  Set the key `haproxy/<env>/tiers` to `off` in each region. This needs no reload.
    3.  Revert the Phase 3 change and deploy a new HAProxy release.
    The Phase 1 state-file change has its own rollback: revert it and deploy a new HAProxy release.
*   **Performance**: The server lines grow by about 4 times. Each HAProxy sends 1 more agent check to each shard.
    The Phase 2 cost render in the lab (10 regions, prod-8x8 shard counts) has these limits, compared with the same render before Phase 3:
    *   Render time, `haproxy -c` time, and reload time: at most 2 times.
    *   Memory: at most 1.5 times.
    *   Prometheus series per HAProxy: at most 5 times.
    If a limit fails, set `haproxy_tier_2_region_count` to 8 or more. Tier 3 is then empty and not rendered, which gives 2 tiers (Alternative G2).
*   **Security**: `?release=` can already name any backend, shard backends included. Tier backends add more names that it can reach. A pattern check on `?release=` is separate work.

--------------------------------------------------------------------------------

## Detailed Implementation Plan

### Phases

Phases 1, 3, and 4 are pull requests. Phase 2 is a lab gate. Phase 5 is Consul KV writes.
A phase starts only after the gate of the phase before it passes.

An infra-configuration change reaches an HAProxy only on a new HAProxy release branch.
`haproxy-create-release` builds that release, and `haproxy-recycle` replaces the instances.
A phase merges, and stage-8x8 gets a release. The stage check passes before the prod-8x8 release.

| Phase | Change | Where | Gate |
|---|---|---|---|
| 1 | State file: items 1 and 2 | infra-configuration | Before merge: lab test 8 passes. Before the prod-8x8 release: on stage-8x8, a reload keeps drained servers drained. Before Phase 3: 7 days in prod-8x8 with no `HAProxy_Reconfig_Failed`, and no `HAProxy_Redispatch_Rate_High` within 10 minutes after a reload. |
| 2 | Lab tests 1-7, 9-12, and 14-17, and the cost render, on the Phase 3 branch | Local lab (scratch directory) | Every test passes, and the cost limits in Performance hold. If one of the 4 claims in Open Questions fails, stop and revise this design. |
| 3 | Tier backends, rules, and switch: items 3-9 | infra-configuration | Before the prod-8x8 release: the render check on stage-8x8 passes. |
| 4 | Alerts: item 10 | infra-provisioning | `promtool check rules` passes, and both rules appear in `/api/v1/rules` on stage-8x8. |
| 5 | Switch on, region by region | Consul KV | The production checks pass for each region. |

### Phase 1: agent state across reloads

#### 1. `ansible/roles/hcv-haproxy-configure/templates/haproxy.cfg.template.j2` (Modify)

*   **Type / Scope**: Jinja template that renders a consul-template template for `haproxy.cfg`.
*   **Proposed Changes**:
    1.  Add `server-state-file {{ haproxy_state_file }}` to `global`.
    2.  Add `load-server-state-from-file global` to `defaults global_defaults`.
*   **Why**: Technical Plan section 4. `ExecReload` and `ExecStop` already write the file, so no other code file changes.

#### 2. `README_HAPROXY.md` (Modify)

*   **Type / Scope**: Documentation.
*   **Proposed Changes**: In "configuring haproxy", add 1 line: a reload restores agent state from `haproxy_state_file`.
*   **Why**: Lab test 8 passes before this merges, so the line states a checked fact.

### Phase 3: tier backends, rules, and switch

#### 3. `ansible/roles/hcv-haproxy-configure/templates/haproxy.cfg.template.j2` (Modify)

*   **Type / Scope**: Jinja template that renders a consul-template template for `haproxy.cfg`.
*   **Proposed Changes**: Line numbers refer to the template before Phase 1. Phase 1 adds 2 lines above them.
    1.  **Tier list.** After the namespace block at lines 58-63, split `ns.haproxy_datacenters` (`dcs` below) into a list of 3 region lists.
        With `n` = `haproxy_tier_2_region_count | int`: `[dcs[:1], dcs[1:1 + n], dcs[1 + n:]]`.
        The index in this list is the tier number minus 1. Tier numbers stay fixed. If a list is empty, skip that tier, and do not renumber.
    2.  **Switch variable.** After the tenant pin lines (line 229), add:
        `http-request set-var(req.tiers_on) str(tiers),map({{ haproxy_tier_map_path }},off)`.
    3.  **Route variable.** After the switch variable, add these 2 lines. The condition is the same as the pin rule at line 271.

        ```
        http-request set-var(req.route_release) var(req.live_backend)
        http-request set-var(req.route_release) var(req.tenant_pin) if { var(req.tenant_pin) -m found } { var(req.tenant_pin),nbsrv gt 0 }
        ```

    4.  **Tier rules.** Put them after the standalone backend rules (line 268) and before the pin rule (line 271).
        Add a consul-template `range` over `scratch.MapValues "releases"`.
        Inside it, a Jinja loop over the tiers writes 1 rule per tier:

        ```
        use_backend release-<R>-t<k> if { var(req.tiers_on) -m str on } { var(req.route_release) -m str release-<R> } { nbsrv(release-<R>-t<k>) gt 0 }
        ```

        The `releases` scratch map is already filled at line 261, so it is ready at this point.
        After that range, add a second `range` over the releases with the same Jinja loop. It writes the live-release rules:

        ```
        use_backend release-<R>-t<k> if { var(req.tiers_on) -m str on } { var(req.live_backend) -m str release-<R> } { var(req.route_release) -m reg ^release-[0-9]+$ } { nbsrv(release-<R>-t<k>) gt 0 }
        ```

        `req.live_backend` is the existing variable that line 221 sets from `live.map`.
    5.  **Tier backends.** After the `release-N` loop (line 368), add a consul-template `range` over the releases. Inside it, a Jinja loop over tier k writes 1 backend:

        ```
        backend release-<R>-t<k> from global_defaults
          acl stick_token hdr_reg(X-Room) .+
          acl stick_token_flag hdr_reg(X-StickTokenFlag) .+
          option forwardfor
          default-server maxconn 2000000 inter {{ haproxy_check_interval }} fall {{ haproxy_backend_fall_count }} rise {{ haproxy_backend_rise_count }}
          balance hdr(X-StickToken)
          hash-type consistent {{ haproxy_hash_function }}
          hash-balance-factor 150
          stick match hdr(X-StickToken) table {{ haproxy_backend_name }} if stick_token
          stick store-request hdr(X-StickToken) table {{ haproxy_backend_name }} if stick_token stick_token_flag
          # for each region in tier k, each passing shard S in it with release R:
          server <R>-<S> <addr>:<http_backend_port> id <shard_id+10> ssl verify none no-check agent-check agent-port <signal_sidecar_agent_port> agent-inter <HAPROXY_AGENT_CHECK_INTERVAL> weight 256
          # for each tier j and each region in tier j (Jinja loops), each passing shard S in it, if j != k or release(S) != R:
          server <R>-fallback-<S> <addr>:<http_backend_port> id <shard_id+10> ssl verify none weight 0 track release-<release(S)>-t<j>/<release(S)>-<S>
        ```

        For j != k, a Jinja `{% if %}` writes every shard of the region as a fallback line.
        For j == k, a consul-template `{{ if ne $shard.ServiceMeta.release_number $release_number }}` writes only shards of other releases.
        Copy the `default-server` line from `release-N` (line 347) exactly.
        Without `fall` and `rise`, HAProxy uses its own defaults, 3 and 2, not the role values 2 and 3 (`defaults/main.yml` lines 6 and 9).
        The weight-0 lines get no `check` and no `agent-check`, because a tracking server must not have its own check.
        The shard data comes from `service "signal@<dc>"` without `|any`, as in `release-N`.
*   **Why**: Changes 1 and 5 implement Technical Plan section 1. Changes 3 and 4 implement section 2. Change 2 implements section 3.

#### 4. `ansible/roles/hcv-haproxy-configure/defaults/main.yml` (Modify)

*   **Type / Scope**: Role defaults.
*   **Proposed Changes**: Add `haproxy_tier_map_path: /etc/haproxy/maps/tiers.map` and `haproxy_tier_2_region_count: 2`.
*   **Why**: The template, the role tasks, and 2 playbooks read the path. The template reads the count.

#### 5. `ansible/roles/hcv-haproxy-configure/tasks/main.yml` (Modify)

*   **Type / Scope**: Role tasks.
*   **Proposed Changes**: After the task "Write health map file with haproxy_health_up_map_value", add 1 task:

    ```yaml
    - name: Write tier map file if missing
      ansible.builtin.copy:
        mode: 0644
        dest: "{{ haproxy_tier_map_path }}"
        content: "tiers off\n"
        force: false
    ```

*   **Why**: `haproxy -c` fails if a map file that the config reads is missing. consul-template can run the config check before it writes `tiers.map`.
    `force: false` keeps the value that consul-template wrote.

#### 6. `ansible/roles/hcv-haproxy-configure/files/tiers.map.template` (Create)

*   **Type / Scope**: consul-template template for the switch map.
*   **Proposed Changes**: The file has 1 line:

    ```
    {{ $tiers_key := print "haproxy/" (env "ENVIRONMENT") "/tiers" }}tiers {{ if eq (keyOrDefault $tiers_key "off") "on" }}on{{ else }}off{{ end }}
    ```

*   **Why**: The value is a plain string with no JSON encoding. Only the exact value `on` turns the tiers on.
    `keyOrDefault` does not wait for a missing key, so a new environment renders `tiers off`.

#### 7. `ansible/configure-haproxy-local.yml` (Modify)

*   **Type / Scope**: Playbook that configures consul-template on each HAProxy.
*   **Proposed Changes**:
    1.  Add this entry to `consul_template_templates_default`, after the `tenant.map.template` entry:

        ```yaml
              - name: "tiers.map.template"
                dest: "{{ haproxy_tier_map_path }}"
                cmd: "/usr/local/bin/update-haproxy-map.sh {{ haproxy_tier_map_path }}"
                perms: 0640
                backup: false
        ```

    2.  Add `- src: roles/hcv-haproxy-configure/files/tiers.map.template` to `consul_template_template_files`.
*   **Why**: `live.map` and `tenant.map` use the same consul-template mechanism. `update-haproxy-map.sh` loads the map through the admin socket with no reload.
    consul-template also renders the map on a new HAProxy, so a recycle keeps the value of the key.

#### 8. `ansible/jvb-colibri-proxy-nginx.yml` (Modify)

*   **Type / Scope**: Playbook that rewrites the consul-template config on an HAProxy for the colibri proxy.
*   **Proposed Changes**: Add the same `tiers.map.template` entry as item 7 to `consul_template_templates`, after the `tenant.map.template` entry.
    Add the same `src` line to its template file list.
*   **Why**: This playbook sets its own full template list, and the consul-template role writes the whole config from it.
    Without the entry, consul-template on that HAProxy stops watching `haproxy/<env>/tiers`, and the off switch does nothing there.

#### 9. `README_HAPROXY.md` (Modify)

*   **Type / Scope**: Documentation.
*   **Proposed Changes**:
    1.  Add a section "region failover tiers" after "tenant pinning". It describes:
        *   The 3 tier backends per release, and that the regions in each tier differ for each HAProxy region.
        *   That the order comes from `haproxy_regions_by_region`, filtered to the regions in `consul_wan_regions_oracle`.
        *   The live-release rules that catch a pinned release with no usable tier.
        *   The switch: the Consul key `haproxy/<env>/tiers`, the `consul kv put -datacenter` command for 1 region, and the `set map` test on 1 HAProxy.
        *   The query for sessions per tier backend: `sum by (host, proxy) (rate(haproxy_backend_sessions_total{proxy=~"release-[0-9]+-t[123]"}[5m]))`.
    2.  In "haproxy for jitsi shards" and in the upgrade checklist, mark the `monitor haproxy` job deprecated. Baron alerts on split brains.
*   **Why**: On-call needs the switch and the query during an incident. The README still describes `monitor haproxy` as active.

### Phase 4: alerts

#### 10. `nomad/prometheus.hcl` in infra-provisioning (Modify, separate pull request)

*   **Type / Scope**: Prometheus alert rules, in a different repository.
*   **Proposed Changes**: Add these 2 rules to the `core_service_alerts` group:

    ```yaml
      - alert: HAProxy_Region_Tier_Failover
        expr: sum by (host, proxy) (rate(haproxy_backend_sessions_total{proxy=~"release-[0-9]+-t[23]"}[5m])) > 0
        for: 2m
        labels:
          service: jitsi
          severity: warn
        annotations:
          summary: haproxy {{ $labels.host }} in ${var.dc} sends new rooms to {{ $labels.proxy }}
          description: >-
            HAProxy {{ $labels.host }} in ${var.dc} found no usable shard in an earlier tier,
            and sends new rooms to {{ $labels.proxy }}. The region failed over.
            Check the agent state of the home-region shards.
          dashboard_url: ${var.grafana_url}
          alert_url: https://${var.prometheus_hostname}/alerts?search=haproxy_region_tier_failover
      - alert: HAProxy_No_Usable_Shards
        expr: sum by (host) (haproxy_backend_active_servers{proxy=~"release-[0-9]+"} + haproxy_backend_backup_servers{proxy=~"release-[0-9]+"}) == 0
        for: 1m
        labels:
          service: jitsi
          severity: severe
          page: true
        annotations:
          summary: haproxy {{ $labels.host }} in ${var.dc} has no usable shard
          description: >-
            HAProxy {{ $labels.host }} in ${var.dc} has 0 UP servers in every release backend.
            It returns 503 for every new room. Check the agent state of all shards.
          dashboard_url: ${var.grafana_url}
          alert_url: https://${var.prometheus_hostname}/alerts?search=haproxy_no_usable_shards
    ```

    The page rule has no `scope: global`, because the problem is in 1 region's HAProxy.

    `host` names 1 HAProxy, as in `HAProxy_Reconfig_Failed`. The stage check confirms that `haproxy_backend_*` series carry `host`.
    `core_service_alerts` renders only where `var.core_deployment` is true. Deploy with `scripts/deploy-nomad-prometheus.sh`.

    Do not change `Shard_HTTP_5xx_Elevated`. It reads `proxy=~"release-.*"` and extracts the shard with `[0-9]+-(?:fallback-)?(.*)` on the `server` label.
    That regex matches the tier server names `<R>-<S>` and `<R>-fallback-<S>`. A request goes through 1 backend only, so the sum by shard counts each 5xx once.
*   **Why**: Goals 8 and 9 need a page when HAProxy has no usable shard, and a failover signal.

#### Files checked that need no change

*   `ansible/roles/hcv-haproxy-configure/templates/haproxy.service.j2`: `ExecReload` and `ExecStop` already write the state file.
*   `ansible/roles/hcv-haproxy-configure/files/haproxy-configurator-payload.sh`: it reloads with `service haproxy reload`, so `ExecReload` runs.
*   `ansible/roles/hcv-haproxy-configure/files/update-haproxy-map.sh`: it loads any map file through the admin socket.
    On first boot, `prepare map` can fail before HAProxy loads a config that uses `tiers.map`. It then sends `map_update_failed:1`. This is expected once.
*   `ansible/roles/hcv-haproxy-configure/files/live.map.template` and `tenant.map.template`: the tier rules read the maps as they are.
*   `ansible/roles/hcv-haproxy-status/tasks/main.yml`: the `monitor haproxy` job that uses it is deprecated. Baron replaced it, and Baron alerts but does not patch.
*   `ansible/roles/hcv-haproxy-set-stick-table/tasks/main.yml`: it patches entries by `server_id`. Tier lines keep `shard_id + 10`.
*   `ansible/haproxy-set-release-ga.yml`: its `grep -q "backend <release>"` also matches tier backends. `release-N` and its tiers render from the same `releases` scratch map, so the check stays valid.
*   `vo_meetings_haproxy-knight` (`src/knight/app.py`): it parses `show servers state` only for servers named `shard-*`. It returns `show stat` unparsed.
*   `vo_meetings_baron` (`src/baron/inconsistency_detector.py`): it reads `server_id` from the stick table and computes `shard_id = server_id - 10`. Tier lines keep the same ids.
*   `HAProxy_Shard_Unhealthy` in `prometheus.hcl`: it groups `haproxy_agent_health` by `sv`. Tier agent lines reuse the `<R>-<S>` names, so their series merge with `release-N`. This is harmless.

### Verification Plan

*   **Static Analysis & Linting**:
    *   `ansible-lint ansible/configure-haproxy-local.yml ansible/jvb-colibri-proxy-nginx.yml ansible/roles/hcv-haproxy-configure`.
    *   `ansible-playbook --syntax-check --vault-password-file .vault-password.txt ansible/configure-haproxy-local.yml ansible/jvb-colibri-proxy-nginx.yml`.
    *   `promtool check rules` on the 2 Phase 4 rules, copied into a plain rules file with `${var.dc}` replaced by `lab`.
*   **Render check on stage-8x8** (after the Phase 3 stage release, with no Consul key `haproxy/stage-8x8/tiers`):
    *   `haproxy -c -f /etc/haproxy/haproxy.cfg` passes.
    *   `/etc/haproxy/maps/tiers.map` holds `tiers off`.
    *   `show stat` lists `release-<R>-t1` and `release-<R>-t2` for each release. stage-8x8 has 2 regions, so tier 3 is empty and not rendered.
    *   For each release R and tier k, the weight-256 servers are the passing `signal` shards with `release_number` R in the regions of tier k. Compare the `show stat` rows with `weight` 256 against `consul catalog` for each region.
    *   The `release-N`, shard, and `nodes` sections are identical to the render before Phase 3.
    *   The `haproxy_backend_*` series in stage-8x8 Prometheus carry a `host` label.
    *   Create rooms, then reload 1 HAProxy behind the load balancer drain. Every stick entry is still in `show table nodes`, and each room stays on its shard. (Lab test 13 moved here, because the lab has no load balancer.)
*   **Lab** (HAProxy 2.8, in a scratch directory, not committed). The lab renders the real 2-stage template against fake data, so it needs no stage HAProxy and no release.
    *   **Render:** Start 1 Consul dev agent for each fake region (`consul agent -dev -datacenter=lab-<region>`, separate ports), joined with `consul join -wan`.
        Register `signal` services with the ServiceMeta fields `release_number`, `shard`, `shard_id`, `http_backend_port`, and `signal_sidecar_agent_port`.
        Render the Jinja stage with `ansible localhost -m template`. Then render with `consul-template -once` against the region-1 agent.
    *   **Functional lab:** 4 regions with 2-3 shards each, and 2 releases. 2 HAProxies with a `peers` section of the 2.
        With `haproxy_tier_2_region_count: 2`, tier 2 holds regions 2 and 3, and tier 3 holds region 4.
    *   **Cost render:** 10 regions, with the prod-8x8 shard count of each region from `consul catalog`. Measure the Performance limits on this render, against the same render of the template before Phase 3.
    *   **Stub shard:** 1 `listen` section per shard: `bind :<port> ssl crt <lab cert>` and `http-request return status 200 string <shard>`.
    *   **Stub agent:** `socat TCP-LISTEN:<port>,fork SYSTEM:'cat /tmp/agent-<n>'`. The file holds the reply, for example `up ready 100%`.
    *   **Load:** `curl -X POST "https://<haproxy>/http-bind?room=<name>"` for each new room. The `/http-bind` path makes HAProxy set `X-StickTokenFlag`, so HAProxy stores the stick entry. Count rooms per shard from the stub replies.
    *   **Split rooms:** Send the first request of each room to both HAProxies at the same time. A room is split if the 2 replies name different shards.
        Do not compare `show table nodes`, because peers make the 2 tables converge.
    *   **Alert tests:** Write a `promtool test rules` file with `input_series` for each alert case, against the plain rules file from the static checks.
*   **Lab tests.** Test 8 is the gate of Phase 1, and it runs on the current template plus item 1. The other tests are the Phase 2 gate:
    1.  Record `nbsrv` and `haproxy_backend_active_servers` for each state. The expected `nbsrv` values are: `up ready` 1, `up drain` 0, `up ready 0%` 0, `down` 0, a stopped agent after a drain 0, and 0 usable active servers with 1 usable backup 1.
        Confirm that the 2 values are equal when a backend has no backups.
    2.  Confirm that `haproxy -c` accepts a `track` to an agent-only server in a backend that comes later in the file.
    3.  Confirm that a weight-0 `track` server goes DOWN and UP with its agent-checked server.
        Count the agent `down` replies that mark a server DOWN in `release-N` and in a tier backend. The 2 counts are equal.
    4.  Send 1000 new stick tokens. They stay in the home region. With the home region drained, they spread over regions 2 and 3. The busiest shard gets at most 1.5 times the mean. With tier 2 also drained, they move to region 4.
    5.  A live room stays on a drained home shard through both HAProxies. A room created during failover stays on its tier-2 shard after the home region recovers. Test with and without `X-Room`.
    6.  Repeat test 4 with a tenant pin and with `?release=release-<n>`. Pinned rooms use the tiers of the pinned release.
    7.  Change `live.map` with `set map`. New rooms use the tiers of the new live release with no reload.
    8.  Drain shards, then reload with the state file. Drained servers stay drained, and agent weights stay the same.
        Start HAProxy with an empty state file. HAProxy starts. Start HAProxy with no state file. HAProxy starts.
    9.  Run 2 HAProxies with agent timers out of phase. Count split rooms during drain changes, first with the switch off and then on.
        The split count with the switch on is not higher than with it off.
    10. Drain every shard. HAProxy returns 503, and the `HAProxy_No_Usable_Shards` promtool case fires.
    11. Set the Consul key to `on`, then to `off`. Routing changes with no reload.
        Set the key to `On` and then to `true`. The map holds `tiers off` both times.
        Start a new HAProxy. It renders the current value of the key.
    12. Drain every shard of a pinned release in every region. Pinned rooms spread over tier 1 of the live release.
        Send `?release=<shard>`. The room goes to that shard backend.
    13. Moved to the stage-8x8 render check.
    14. Drain every shard of the live release in every region. New rooms go to `release-<live>` and its backups.
    15. Set `live.map` to a release with no tier rules. New rooms use the live rule.
    16. Turn the switch on for 1 HAProxy and off for the other. A meeting stays on 1 shard through both.
    17. Make sessions flow into a tier-2 backend. The `HAProxy_Region_Tier_Failover` promtool case fires.
*   **Production checks for each region in Phase 5**: compare the 5xx ratio of the region's `www-http` frontends, 24 hours before and 24 hours after the switch:
    `sum(rate(haproxy_frontend_http_responses_total{proxy="www-http",code="5xx"}[24h])) / sum(rate(haproxy_frontend_http_requests_total{proxy="www-http"}[24h]))`.
    If the 24 hours after are above 1.5 times the 24 hours before, roll back. Wait 24 hours before the next region.

--------------------------------------------------------------------------------

*Drafted with EGM*
