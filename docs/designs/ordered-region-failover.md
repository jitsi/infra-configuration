# Ordered Region Failover for Signal Shards in HAProxy

*   **Author:** Aaron van Meerten
*   **Status:** Draft
*   **Date:** 2026-11-05

--------------------------------------------------------------------------------

## Overview

The HAProxy config for signal shards fails a region over to 1 remote shard, not to the next region.
This design adds 1 HAProxy backend for each step in the failover order, called a tier.
When every home-region shard of a release is unusable, new rooms spread over all shards of the next region.
The next region comes from `haproxy_regions_by_region` in `config/vars.yml`.
Existing meetings stay on their shard, in every region.

The change is in the `hcv-haproxy-configure` role, mainly in
`ansible/roles/hcv-haproxy-configure/templates/haproxy.cfg.template.j2`.
It needs no change to signal-sidecar, and it ships first.
A separate signal-sidecar change adds a prosody CPU drain at 80%.
That change ships only after this change runs in production.

The users are the people in meetings during a regional overload, and the on-call engineers.

### Glossary

| Term | Meaning |
|---|---|
| Shard | 1 signal node: prosody, jicofo, and signal-sidecar on 1 host. This document drops the `prod-8x8-` prefix. |
| Region | An OCI region, for example ap-mumbai-1. The template calls `<env>-<region>` a datacenter. This document uses "region" only. |
| Home region | The region of the HAProxy that receives the request. |
| Release | A set of shards with the same `release_number` in Consul. The live release comes from the Consul key `releases/<env>/live` and the live map. |
| Release backend | The existing backend `release-N`. It lists home-region shards of release N as active servers, and every other passing shard as `backup`. |
| Tier | 1 step in the failover order for 1 release. Tier 1 is the home region. Tier 2 is the next region in `haproxy_regions_by_region`, and so on. |
| Tier backend | A new backend for 1 tier, for example `release-7068-t2-eu-frankfurt-1`. It lists every passing shard of every release. Only the shards of its release and region have a weight above 0. |
| Stick token | The `X-StickToken` header. HAProxy stores it in the shared `nodes` table and uses it to send the next request of a meeting to the same shard. Peers copy every write to every HAProxy. |
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
The order of backups comes from the consul-template sort order, probably by node name.
Nobody chose this order. For example, `s100` sorts before `s12`.

So a failover overloads 1 remote shard at a time.
That shard can then fail, and each failure moves every meeting on it.

This design does not add capacity.
The live release had only 2 shards in ap-mumbai-1, and they ran at 100% CPU.
A spread over the next region lowers the peak load per shard, but the total load stays the same.
If the next region is also near its limit, the overflow moves on to the region after it.

## Goals

1.  If no home-region shard of the live release is usable, HAProxy spreads new rooms over the next region's usable shards.
    The busiest shard of that region gets at most 1.5 times the mean session rate of that region.
2.  HAProxy sends new rooms to tier k+1 only when tier k has `nbsrv` 0.
3.  Overflow cascades to further regions in `haproxy_regions_by_region` order.
4.  Existing meetings stay on their shard.
    This includes cross-region meetings and meetings on shards of other releases.
5.  HAProxy uses shards of other releases only when no region of the release has a usable server.
6.  Every release gets tier backends, canary releases included.
7.  Agent drain state and agent weight survive an HAProxy reload.
8.  A runtime map entry turns the tier rules on and off with no reload.
9.  On-call gets a page when an HAProxy has 0 usable servers in all tier and release backends.
10. Metrics show tier failovers per region per hour, and the backend that served each request.
11. These measures do not rise: split rooms, 503 responses, and join errors.

## Non-Goals

*   Any change to signal-sidecar. The prosody CPU drain is a separate change.
*   A change to the `release-N` backends or to the `nbsrv` check of the tenant pin rule.
*   A maintenance response for `xmpp-websocket`, a user-facing 503 page, or a client change. These are separate follow-up work.
*   Changes to shard-specific backends and paths. They use `no-check` and ignore drain.
*   Changes to the size or expiry of the stick table.
*   More shards in ap-mumbai-1, or any other capacity change.
*   A limit on how far overflow cascades. The author accepts the cascade.

## Open Questions

*   **Unverified HAProxy behavior**: The design depends on 2 claims from the HAProxy 2.8 source. No lab test confirms them yet.
    *   `nbsrv` returns 1 when no active server is usable but a backup is usable.
    *   A weight-0 server that uses `track` follows the UP and DOWN state of an agent-checked server.
*   **Server-state file**: A lab test must show that agent drain and weight survive a reload with `load-server-state-from-file`.
*   **Metric cardinality**: telegraf and the Prometheus exporter on port 8405 collect metrics for every server line.
    Tier backends multiply the server lines by about (regions + 1). The lab must count the series before production.
    A drop rule for server-level series of tier backends is possible, but it also hides 5xx counts on weight-0 copies.
*   **Failover budget**: The concept asks for a budget of tier failovers per region per hour, but gives no number.

## Critical User Journeys (CUJs)

### CUJ 1: Home region fails over to the next region

*   **Given**: The tier switch is on. Both live-release shards in ap-mumbai-1 are drained or DOWN. eu-frankfurt-1 has 3 usable live-release shards.
*   **When**: A user in India opens a new room. The request reaches the ap-mumbai-1 HAProxy.
*   **Then**: HAProxy uses `release-7068-t2-eu-frankfurt-1`. The room hashes to 1 of the 3 eu-frankfurt-1 shards. Other new rooms spread over all 3.

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
*   **Then**: HAProxy uses `release-7070-t2-eu-frankfurt-1`, not the live release.

### CUJ 5: On-call turns the tiers off

*   **Given**: The tier switch is on, and tier routing misbehaves.
*   **When**: On-call runs the switch playbook with the value `off` for 1 HAProxy, 1 region, or all HAProxies.
*   **Then**: New requests use today's rules at once, with no reload. The value stays `off` after a reload or a rerun of the role.

## Technical Plan (Architecture)

All changes are in the `hcv-haproxy-configure` role, except the alert rules.
The template has 2 render stages.
Ansible (Jinja) knows the region order of this HAProxy.
consul-template knows the releases and the shards.

### 1. Tier backends

consul-template writes 1 tier backend for each release R and each region k in this HAProxy's region order.
The name is `release-R-tk-<region>`, for example `release-7068-t2-eu-frankfurt-1`.
The region order comes from `ns.haproxy_datacenters`, so tier numbers differ between HAProxies in different regions.

Each tier backend copies the balance and stick lines of `release-N`:
`balance hdr(X-StickToken)`, `hash-type consistent`, `hash-balance-factor 150`, and `stick match` and `stick store-request` on the `nodes` table.
The `nodes` table uses `srvkey addr`, so a stick match finds a server by address and port in any backend.

Each tier backend lists every Consul-passing shard of every release, in 2 kinds of server lines:

| Server | Which shards | Line |
|---|---|---|
| `R-<shard>` | Shards of release R in region k | `weight 256`, `agent-check` on the signal-sidecar agent port, as in `release-N` today |
| `R-fallback-<shard>` | Every other passing shard | `weight 0`, `track release-R'-tj-<region j>/R'-<shard>`, where R' and j are that shard's own release and region |

Rules for both kinds:

*   No server is `backup`. So `nbsrv` counts only the weight-256 shards that are UP and not drained.
*   Each server keeps the `id` of today, `shard_id + 10`. Same ids give the same positions on the hash ring as the active list of `release-N`.
*   The server names keep the `<release>-` and `<release>-fallback-` forms. The `Shard_HTTP_5xx_Elevated` alert parses these names.
*   A weight-0 server takes no load-balanced traffic. HAProxy still sends a stick match to it if it is UP. A drained server works the same way.
*   Each shard has exactly 1 agent-checked line in the tier backends, in its own release and region. All other copies track that line.
    So each HAProxy sends 1 more agent check to each shard than today, not (regions + 1) times more.

A side effect helps cross-region joins.
Mumbai tier 2 and Frankfurt tier 1 for release R list the same Frankfurt servers with the same ids.
So 2 first joiners of 1 new room, 1 in each region, hash to the same Frankfurt shard.
Today the Mumbai HAProxy sends its joiner to the first backup instead.

### 2. Routing rules

The frontend sets 1 new variable before the `use_backend` rules:

*   `req.route_release` is the tenant pin when the pin's `release-N` has `nbsrv` above 0. Otherwise it is the live release.
    The tenant pin includes `?release=`, as today.
*   `req.tiers_on` is the value of the `tiers` key in the new switch map. A missing key means `off`.

consul-template writes 1 rule for each release R and each tier k, after the shard-specific rules and before the pin rule:

```
use_backend release-R-tk-<region> if { var(req.tiers_on) -m str on } { var(req.route_release) -m str release-R } { nbsrv(release-R-tk-<region>) gt 0 }
```

Every backend name in these rules is static, so `haproxy -c` rejects a missing backend.
The rules for 1 release follow its tier order. For 3 releases and 9 regions, that is 27 rules.
HAProxy stops at the first false condition, so most rules cost 1 string compare.

The pin rule and the live rule stay as they are, after the tier rules.
They catch a request when every tier of its release has `nbsrv` 0, or when the switch is off.
Then `release-N` falls back to other releases through its backup chain, as today.

```text
request
  |
  +-- shard path or X-Room ends in _<shard> --> shard backend          (unchanged)
  |
  +-- tiers on AND route_release = R:
  |      nbsrv(release-R-t1-<home>) > 0 --> tier 1: hash over home shards of R
  |      nbsrv(release-R-t2-<next>) > 0 --> tier 2: hash over next-region shards of R
  |      ...                                ...through tier 9
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
It works like `up.map`:

*   The role writes the file with `haproxy_tier_map_value` (default `off`). If the file exists, the role keeps its current value.
*   A new playbook writes the file and sends `set map` to the admin socket. A limit on the inventory selects 1 HAProxy, 1 region, or all.
*   A reload reads the file, so the runtime value and the file value stay the same.

### 4. Agent state across reloads

`ExecReload` in `haproxy.service.j2` already writes `show servers state` to `haproxy_state_file` before each reload.
The config never reads that file. This design adds `server-state-file` to `global` and `load-server-state-from-file global` to `defaults global_defaults`.
After a reload, servers keep their drain state and agent weight. They do not start at UP and weight 256.

Without this, every drained home shard counts in `nbsrv` for up to 10 seconds after each reload.
Reloads follow every change in Consul passing state in any of 9 regions, so they are likely during an incident.

`haproxy-configurator-payload.sh` drains the HAProxy from the OCI load balancer before the reload, and undrains it after.
This gives the stick table time to fill from the local peer before traffic returns.
The state file adds agent state to that protection.

A crash restart skips `ExecStop`, so HAProxy can load a stale file.
The agent check corrects each server within 1 agent interval, 10 seconds.
That is the same worst case as today.

### 5. Telemetry and alerts

*   A new response header `X-Proxy-Backend` carries the backend name, next to `X-Proxy-Region`.
*   The Prometheus exporter already gives `haproxy_backend_active_servers` and `haproxy_backend_sessions_total` for each backend.
    Tier names carry the tier and the region, so no new HAProxy counter is necessary.
*   New alert rules in infra-provisioning `nomad/prometheus.hcl`:
    *   Warn when sessions flow into a tier-2 or later backend. This means that a region failed over.
    *   Page when an HAProxy has 0 active and 0 backup servers in all `release-` backends. Then HAProxy returns 503.
    *   Record tier failovers per region per hour. The budget number is an open question.

### 6. What does not change

*   The `release-N` backends, the pin rule, the live rule, and the `nodes` backend.
*   Shard-specific and standalone backends.
*   The stick table: its key, size, expiry, and peers.
*   signal-sidecar and its agent replies.

### Known risks

*   **Return wave**: When 1 drained home shard returns, `nbsrv` of tier 1 becomes 1. Every new room of the region then goes to it.
    Today the same shard gets the same wave. On 2026-11-04, s27 changed state 4 times in 6 minutes.
    Exit hysteresis in signal-sidecar is the fix, and it is not part of this design.
*   **Split rooms**: Each HAProxy reads agent state on its own 10-second timer.
    During a drain change, 2 first joiners of 1 new room can land in 2 regions.
*   **Mixed fleet**: During rollout, HAProxies with the switch on and off route new rooms differently. This happens only when tier 1 is empty.
*   **Config size**: The server lines grow by about (regions + 1) times.
    The lab and stage-8x8 must measure render time, `haproxy -c` time, and reload time.

## Alternatives Considered

### Alternative A: `option allbackups` in the release backends

*   **Pros**: 1-line change. New rooms spread over all backups, not 1.
*   **Cons**: HAProxy uses every backup region at the same time. ap-mumbai-1 can then fail over to us-phoenix-1 before eu-frankfurt-1 or ap-tokyo-1. `no option allbackups` is in the template from the first consul-template version (#125).
*   **Reason for Rejection**: Rejected by author: it ignores the region order in `haproxy_regions_by_region`.

### Alternative B: Tier backends that list only the shards of their region

*   **Pros**: Smaller backends. No weight-0 copies and no `track` lines.
*   **Cons**: A stick entry that points to a shard outside the backend finds no server. HAProxy hashes the request again, and the meeting moves.
*   **Reason for Rejection**: Rejected by author: cross-region meetings and meetings on other releases would break.

### Alternative C: Change `release-N` in place

*   **Pros**: No new backends. Fewer server lines.
*   **Cons**: The pin rule checks `nbsrv` of `release-N`, and today that count includes the first usable backup. Without backups, the check fails when the pinned release's home shards drain. The tenant then moves to the live release.
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

### Alternative G: Only 2 tiers

*   **Pros**: Covers the observed case. 6 rules for 3 releases, not 27.
*   **Cons**: After tier 2, failover goes back to the 1-shard backup chain.
*   **Reason for Rejection**: Rejected by author: overflow must cascade in region order (author decision 3). The extra rules cost 1 string compare each.

### Alternative H: Rotate the `release-N` template for each tier, with other regions as `backup`

*   **Pros**: 1 template loop. Every tier backend holds every shard.
*   **Cons**: `nbsrv` counts a usable backup, so a tier backend never reports 0. Each tier needs a separate probe backend to count its active servers.
*   **Reason for Rejection**: Rejected by author: it doubles the backends and gives the same routing as the chosen design.

### Alternative I: Region backends plus `in_table` routing of stuck rooms to `release-N`

*   **Pros**: Small change to the order of the rules.
*   **Cons**: `in_table` does not check the state of the server. A stuck room on a DOWN shard goes to `release-N` and then to the 1-shard backup chain.
*   **Reason for Rejection**: Rejected by author: it keeps the 1-shard chain for rooms on failed shards.

### Alternative J: More shards in ap-mumbai-1

*   **Pros**: A routine release change. No HAProxy change.
*   **Cons**: It does not fix the 1-shard failover. Any region with few shards can fail the same way.
*   **Reason for Rejection**: Rejected by author: it does not replace this design. It is a capacity change and can still happen separately.

--------------------------------------------------------------------------------

## Non-Functional Requirements

*   **Rollout**:
    1.  Deploy the role with `haproxy_tier_map_value: off`. The tier backends exist, but no rule sends traffic to them.
    2.  On 1 stage-8x8 HAProxy, check `show stat` and `nbsrv` of each tier backend.
    3.  Turn the switch on for 1 HAProxy in ap-mumbai-1, then all ap-mumbai-1 HAProxies, then each other region.
    4.  A mixed fleet works, because the stick-table key and `srvkey addr` do not change.
*   **Rollback**:
    1.  If the signal-sidecar CPU drain is on in the region, turn it off.
    2.  Turn the tier switch off. This needs no reload.
    3.  Revert the template change and run the role.
*   **Performance**: The server lines grow by about (regions + 1) times. Each HAProxy sends 1 more agent check to each shard.
    Measure render time, `haproxy -c` time, reload time, and memory on stage-8x8 before production.
*   **Security**: `X-Proxy-Backend` shows the release number to clients. `?release=` already exposes release numbers, so this adds no new information.

--------------------------------------------------------------------------------

## Detailed Implementation Plan

### Target Files to Create/Modify

#### 1. `ansible/roles/hcv-haproxy-configure/templates/haproxy.cfg.template.j2` (Modify)

*   **Type / Scope**: Jinja template that renders a consul-template template for `haproxy.cfg`.
*   **Proposed Changes**:
    1.  **Region list.** In the namespace block at lines 58-63, also append the bare region to a new list `ns.haproxy_tier_regions`.
        The index in this list is the tier number minus 1. The region is part of the tier backend name.
    2.  **State file.** Add `server-state-file {{ haproxy_state_file }}` to `global`. Add `load-server-state-from-file global` to `defaults global_defaults`.
    3.  **Switch variable.** After the tenant pin lines (line 229), add:
        `http-request set-var(req.tiers_on) str(tiers),map({{ haproxy_tier_map_path }},off)`.
    4.  **Route variable.** After the switch variable, add 2 lines.
        The first sets `req.route_release` from `req.live_backend`.
        The second overrides it with `req.tenant_pin` if the pin is found and `var(req.tenant_pin),nbsrv gt 0`. This is the same condition as the pin rule at line 271.
    5.  **Response header.** Next to line 247, add `http-response add-header X-Proxy-Backend %b`.
    6.  **Tier rules.** Put them after the standalone backend rules (line 268) and before the pin rule (line 270).
        Add a consul-template `range` over `scratch.MapValues "releases"`.
        Inside it, a Jinja loop over the tier regions writes 1 rule per tier:

        ```
        use_backend release-<R>-t<k>-<region k> if { var(req.tiers_on) -m str on } { var(req.route_release) -m str release-<R> } { nbsrv(release-<R>-t<k>-<region k>) gt 0 }
        ```

        The `releases` scratch map is already filled at line 261, so it is ready at this point.
    7.  **Tier backends.** After the `release-N` loop (line 368), add a consul-template `range` over the releases. Inside it, a Jinja loop over tier k writes 1 backend:

        ```
        backend release-<R>-t<k>-<region k> from global_defaults
          acl stick_token hdr_reg(X-Room) .+
          acl stick_token_flag hdr_reg(X-StickTokenFlag) .+
          option forwardfor
          default-server maxconn 2000000
          balance hdr(X-StickToken)
          hash-type consistent {{ haproxy_hash_function }}
          hash-balance-factor 150
          stick match hdr(X-StickToken) table {{ haproxy_backend_name }} if stick_token
          stick store-request hdr(X-StickToken) table {{ haproxy_backend_name }} if stick_token stick_token_flag
          # for each passing shard S in region k with release R:
          server <R>-<S> <addr>:<http_backend_port> id <shard_id+10> ssl verify none no-check agent-check agent-port <signal_sidecar_agent_port> agent-inter <HAPROXY_AGENT_CHECK_INTERVAL> weight 256
          # for each region j (Jinja loop), each passing shard S in region j, if j != k or release(S) != R:
          server <R>-fallback-<S> <addr>:<http_backend_port> id <shard_id+10> ssl verify none weight 0 track release-<release(S)>-t<j>-<region j>/<release(S)>-<S>
        ```

        The weight-0 lines get no `check` and no `agent-check`, because a tracking server must not have its own check.
        The shard data comes from `service "signal@<dc>"` without `|any`, as in `release-N`.
*   **Why**: This file holds all routing. Each change maps to 1 part of the Technical Plan.

#### 2. `ansible/roles/hcv-haproxy-configure/defaults/main.yml` (Modify)

*   **Type / Scope**: Role defaults.
*   **Proposed Changes**: Add `haproxy_tier_map_path: /etc/haproxy/maps/tiers.map` and `haproxy_tier_map_value: "off"`.
*   **Why**: The template, the role tasks, and the switch playbook read these 2 values.

#### 3. `ansible/roles/hcv-haproxy-configure/tasks/main.yml` (Modify)

*   **Type / Scope**: Role tasks.
*   **Proposed Changes**: Add 4 tasks after the task "Write health map file" (line 212).
    They mirror the 4 health map tasks at lines 189-216.
    1.  Stat `haproxy_tier_map_path`.
    2.  If the file exists, read the value of the `tiers` key.
    3.  If the read succeeds, set `haproxy_tier_map_value` from it.
    4.  Write the file with the content `tiers <value>`.
*   **Why**: HAProxy cannot load a config if a map file that it reads does not exist.
    This role runs before the `consul-template` role in `configure-haproxy-local.yml`, so the file exists before the first render.
    A rerun of the role keeps the value that on-call set.

#### 4. `ansible/haproxy-tier-value.yml` (Create)

*   **Type / Scope**: Playbook.
*   **Proposed Changes**: A copy of `ansible/haproxy-health-value.yml` for the tier map.
    It writes `tiers <haproxy_tier_map_value>` to `haproxy_tier_map_path`.
    Then it sends `set map <path> tiers <value>` to the admin socket.
    The caller selects hosts with the inventory and `--limit`.
*   **Why**: The runtime switch must change with no reload, and the file must match the runtime value.

#### 5. `README_HAPROXY.md` (Modify)

*   **Type / Scope**: Documentation.
*   **Proposed Changes**: Add a section "region failover tiers" after "tenant pinning". It describes:
    *   The tier backend names, and that tier numbers differ for each HAProxy region.
    *   That the order comes from `haproxy_regions_by_region`, without regions that are not in `consul_wan_regions_oracle`.
    *   The switch: the map file, the playbook, and how to limit it to 1 HAProxy.
    *   The Prometheus queries for tier failovers and for the backend that served a request.
    *   That `/tmp/server_state` now restores agent state on reload.
*   **Why**: On-call needs the switch and the queries during an incident.

#### 6. `nomad/prometheus.hcl` in infra-provisioning (Modify, separate pull request)

*   **Type / Scope**: Prometheus alert rules, in a different repository.
*   **Proposed Changes**: Add 2 alerts to the `core_service_alerts` group.
    *   `HAProxy_Region_Tier_Failover` (warn): `sum by (instance, proxy) (rate(haproxy_backend_sessions_total{proxy=~"release-.*-t([2-9]|[1-9][0-9])-.*"}[5m])) > 0` for 2 minutes.
    *   `HAProxy_No_Usable_Shards` (severe, page): `sum by (instance) (haproxy_backend_active_servers{proxy=~"release-.*"} + haproxy_backend_backup_servers{proxy=~"release-.*"}) == 0` for 1 minute.
    Do not change `Shard_HTTP_5xx_Elevated`. Its server-name regex already matches the tier server names.
*   **Why**: The goals need a failover signal and a page when HAProxy has no usable shard.

#### 7. `scripts/set-haproxy-tier-value.sh` in infra-provisioning (Create, separate pull request)

*   **Type / Scope**: Shell wrapper, in a different repository.
*   **Proposed Changes**: A copy of `scripts/set-haproxy-health-value.sh` that runs `ansible/haproxy-tier-value.yml`.
    It reads `HAPROXY_TIER_VALUE` for the value and `HAPROXY_TIER_LIMIT` for `--limit`.
*   **Why**: On-call runs the health switch through this kind of wrapper today. The limit gives the rollout steps of 1 HAProxy, then 1 region.

#### Files checked that need no change

*   `ansible/roles/hcv-haproxy-configure/templates/haproxy.service.j2`: `ExecReload` and `ExecStop` already write the state file.
*   `ansible/roles/hcv-haproxy-configure/files/haproxy-configurator-payload.sh`: it reloads with `service haproxy reload`, so `ExecReload` runs.
*   `ansible/configure-haproxy-local.yml`: the role order already puts `hcv-haproxy-configure` before `consul-template`.
*   `ansible/jvb-colibri-proxy-nginx.yml`: it renders the Jinja stage only for the colibri template. The tier map exists from the main configure run.
*   `ansible/roles/hcv-haproxy-configure/files/live.map.template` and `tenant.map.template`: the tier rules read the maps as they are.

### Verification Plan

*   **Static Analysis & Linting**:
    *   `ansible-lint ansible/haproxy-tier-value.yml ansible/roles/hcv-haproxy-configure`.
    *   `ansible-playbook --syntax-check --vault-password-file .vault-password.txt ansible/configure-haproxy-local.yml ansible/haproxy-tier-value.yml`.
*   **Render check on stage-8x8**: Run the role on 1 stage-8x8 HAProxy with the switch `off`. Then:
    *   `haproxy -c -f /etc/haproxy/haproxy.cfg` passes.
    *   `show stat` lists `release-<R>-t<k>-<region>` for each release and each region.
    *   Each tier backend has exactly the expected weight-256 servers.
    *   Record render time, `haproxy -c` time, reload time, and memory, before and after.
    *   Record the number of series on port 8405 and in telegraf, before and after.
*   **Lab tests** (HAProxy 2.8, 2 peered HAProxies, 3 regions with 2-3 stub agents each, in a scratch directory, not committed):
    1.  Record `nbsrv` and `haproxy_backend_active_servers` for these states: `up ready`, `up drain`, `up ready 0%`, `down`, a stopped agent after a drain, and a backend with backups. Confirm that the 2 values are equal when a backend has no backups.
    2.  Confirm that `haproxy -c` accepts a `track` to an agent-only server in a backend that comes later in the file.
    3.  Confirm that a weight-0 `track` server goes DOWN and UP with its agent-checked server.
    4.  Send 1000 new stick tokens. They stay in the home region. With the home region drained, they spread over region 2. The busiest shard gets at most 1.5 times the mean. With region 2 also drained, they move to region 3.
    5.  A live room stays on a drained home shard through both HAProxies. A room created during failover stays on its region-2 shard after the home region recovers. Test with and without `X-Room`.
    6.  Repeat test 4 with a tenant pin and with `?release=release-<n>`. Pinned rooms use the tiers of the pinned release.
    7.  Change `live.map` with `set map`. New rooms use the tiers of the new live release with no reload.
    8.  Drain shards, then reload with the state file. Drained servers stay drained, and agent weights stay the same.
    9.  Run 2 HAProxies with agent timers out of phase. Count split rooms during drain changes.
    10. Drain every shard. HAProxy returns 503, and `HAProxy_No_Usable_Shards` fires.
    11. Turn the switch on and off with the playbook. Routing changes with no reload. A rerun of the role keeps the value.
*   **Not in this plan**: Stick-table survival across a reload is checked separately. It works today, behind the load balancer drain.
*   **Production checks after each rollout step**: Watch `haproxy_backend_sessions_total` of the tier backends, 503 responses, `haproxy_wredis`, and join errors on `jitsi-oci-hosts-prod-01-oci-metrics`.

--------------------------------------------------------------------------------

*Drafted with EGM*
