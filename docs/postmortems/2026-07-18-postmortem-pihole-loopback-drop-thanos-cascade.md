# Postmortem: Pi-hole Loopback Drop + Thanos Compact Crash Loop - Three Root Causes in One Alert

**Date:** 2026-07-18 | **Duration:** ~2 weeks (intermittent DNS), ~1 day (compact crash loop) | **Severity:** SEV-3
**Author:** Dmitry Stepanov | **Status:** Resolved

---

## Summary

A recurring Uptime Kuma alert - "ArgoCD, Prometheus, and Alertmanager all Down together" - triggered a deep investigation that surfaced three unrelated production issues in a single session: Pi-hole silently dropping DNS queries from `127.0.0.1`, Thanos-compact stuck in a systemd restart loop from a corrupted R2 block, and R2 credentials exposed in a debug session. None caused user-facing outages. All three had been present for days-to-weeks and would have continued to degrade the observability stack.

---

## Impact

- Three homelab services showed intermittent Down in Uptime Kuma (~2-12 min per event, several events per day) for two weeks
- Thanos long-term downsampling paused for ~24 hours (queries still worked - only 5m aggregation for one block window was delayed)
- No public service impact (Grafana served via Cloudflare Tunnel was unaffected)
- Signal quality on `NodeDown` alert had been degraded for months (rule matched every scrape target, not just nodes)

---

## Timeline

| Time (PDT) | Event |
|------------|-------|
| ~2 weeks prior | Pi-hole v6 config regenerated; `dns.listeningMode` defaulted to `LOCAL`. Silent loopback drops begin. |
| 2026-07-17 04:47 | Uptime Kuma: ArgoCD/Prometheus/Alertmanager alerts fire, ~12 min |
| 2026-07-17 09:36 | Same three alerts repeat, ~2 min |
| 2026-07-17 09:37 | Thanos-compact hits `invalid checksum` on block `01KXMPW4MTXD4ZY1KKT8BT3XTH`; systemd `Restart=on-failure` begins loop |
| 2026-07-18 06:24 | Investigation begins from Uptime Kuma pattern |
| 2026-07-18 06:52 | Pi-hole `listeningMode` switched LOCAL -> ALL; loopback root cause resolved |
| 2026-07-18 07:00 | Defense-in-depth: Uptime Kuma migrated to compose with `extra_hosts` for `*.homelab.local` |
| 2026-07-18 07:15 | Host `resolv.conf` gained `options timeout:2 attempts:3 single-request` via NetworkManager |
| 2026-07-18 08:45 | Uptime Kuma alert on `localhost:19194` (Thanos-compact) - revealed second, unrelated issue |
| 2026-07-18 08:54 | Bad block marked `no-downsample-mark.json`; compact resumes normal iteration |
| 2026-07-18 09:11 | R2 credentials rotated (old User API Token -> Account API Token, bucket-scoped); old token deleted |
| 2026-07-18 09:18 | Prometheus alerts refined: `NodeDown` narrowed; four Thanos component `*Down` alerts added |

---

## Root Cause

Three independent faults, connected only by the fact that the first one made the second visible.

### 1. Pi-hole `dns.listeningMode: LOCAL` drops loopback queries

Uptime Kuma runs in Docker with `network_mode: host`. Its `/etc/resolv.conf` is inherited from the host:

```
nameserver 127.0.0.1   # Pi-hole
nameserver 1.1.1.1     # Cloudflare fallback
```

When Pi-hole's `dns.listeningMode` is `LOCAL`, FTL only accepts queries from the local subnet (`192.168.50.0/24`). Queries arriving on `127.0.0.1` are treated as "non-local network" and **silently dropped** with a single log line:

```
WARNING: dnsmasq: ignoring query from non-local network 127.0.0.1
(logged only once)
```

glibc's resolver, after the loopback nameserver times out, falls back to `1.1.1.1`. Cloudflare has no record of `*.homelab.local` and returns NXDOMAIN, which glibc surfaces to the application as `ENOTFOUND`.

Grafana was monitored via its public Cloudflare Tunnel URL (`grafana.sre.dstepanov.dev`) and was therefore unaffected - the only reason the "three services together" pattern was so obvious.

### 2. Thanos-compact crash loop from corrupted downsample block

Thanos-compact, during first-pass downsampling of block `01KXMPW4MTXD4ZY1KKT8BT3XTH` (14 days of raw data, 1.83 billion samples, compaction level 4), hit:

```
error executing compaction: first pass of downsampling failed:
downsampling to 5 min: input block index not valid:
read series: invalid checksum
```

The process exited with status 1. systemd (`Restart=on-failure`) respawned it every minute. Every run performed the same 27-40 second download from R2, then failed on the same block. Loop.

Origin of corruption unclear - most likely an interrupted upload during an earlier network event.

### 3. `NodeDown` alert rule too broad

The rule was defined as:

```yaml
- alert: NodeDown
  expr: up == 0
  for: 1m
```

`up == 0` matches every scrape target. When Thanos-compact died, this rule fired as `NodeDown localhost:19194 is down` - semantically wrong. When Prometheus itself restarted (WAL replay ~2 min), the rule fired for every target simultaneously.

### Why did the DNS fallback to 1.1.1.1 not help?

Same reason as [2026-07-11](./2026-07-11-postmortem-pihole-sqlite-arp-deadlock.md): `1.1.1.1` has no records for `*.homelab.local`. Once glibc gave up on the loopback nameserver, the fallback resolver could only return NXDOMAIN.

---

## 5 Whys

### Fault 1: Silent DNS drops for two weeks

1. Why did Uptime Kuma report Down? -> DNS lookup for `*.homelab.local` returned NXDOMAIN.
2. Why NXDOMAIN? -> Pi-hole did not answer; glibc fell back to `1.1.1.1`, which has no records for the internal domain.
3. Why did Pi-hole not answer? -> FTL dropped the query with `ignoring query from non-local network 127.0.0.1`.
4. Why was `127.0.0.1` considered non-local? -> `dns.listeningMode: LOCAL` restricts FTL to the interface subnet (`192.168.50.0/24`); loopback is outside it.
5. Why did no one notice for two weeks? -> The drop was logged **once** (`logged only once`), no metric was incremented, and no alert existed for it.

### Fault 2: Thanos-compact crash loop

1. Why was `thanos_compact_halted` metric not firing? -> The process died entirely; systemd respawned it before the metric could be scraped as `1`. From Prometheus's view the metric went stale, not to 1.
2. Why did the process die on every run? -> Same corrupted block, same checksum failure.
3. Why was the block corrupt? -> Unknown - most likely partial upload during an earlier network event.
4. Why was there no marker preventing repeat attempts? -> Thanos has `no-downsample-mark.json` for exactly this case, but compact does not auto-mark blocks on failure.
5. Why did no alert catch it? -> `NodeDown` fired for `localhost:19194`, but the name suggested a node problem, not Thanos.

### Fault 3: Overly broad alert

1. Why was `NodeDown` firing on non-nodes? -> `expr: up == 0` has no job selector.
2. Why was there no job selector? -> Original rule was written when only node_exporter was scraped.
3. Why was it never narrowed as scrape targets grew? -> Rule was never revisited; each new false-positive was reasoned-about individually.
4. Why were false-positives not aggregated into a signal to fix the rule? -> Alert names looked plausible enough on receipt ("localhost:19194 is down" reads as *some* problem).
5. Why did the ambiguous name persist? -> No convention that alert names must describe *what* is down, not *that something* is down.

---

## Contributing Factors

- **Docker `network_mode: host`** inherits every host DNS quirk, including any loopback nameserver that the host tolerates but a container cannot.
- **Pi-hole's `logged only once` behavior** - correct for disk hygiene, catastrophic for detectability. No dashboards or alerts consumed this event.
- **Uptime Kuma's target list mixes internal DNS-resolved names with public URLs.** Grafana escaped via Cloudflare Tunnel; had every monitor used internal DNS, the pattern would have been "everything Down together" and would have been harder to correlate to DNS specifically.
- **systemd `Restart=on-failure`** kept Thanos-compact "alive" from `systemctl status`'s perspective, masking that it was in a crash loop.
- **`up == 0` is Prometheus's most tempting foot-gun** - simple, universal, and immediately wrong once you have more than one job.
- **R2 credentials were shared in a debug transcript.** Rotation was fast (~15 min) but the incident depended on operator vigilance, not tooling.

---

## What Helped

- **Uptime Kuma noticed the pattern despite being downstream** of the fault. The "three at once, then all Up" cadence was the tell.
- **`/etc/pihole/FTL.log`** had the one WARNING that explained everything. `grep "non-local"` on the log solved Fault 1.
- **Correlating Thanos-compact logs with process PID** revealed the crash loop (`/proc/<pid>` disappearing between checks).
- **Cloudflare's Account API Token model** made bucket-scoped rotation straightforward - one click, minimal blast radius.

## What Did Not Help

- **Initial focus on the three "affected" services.** ArgoCD, Prometheus, Alertmanager have nothing in common except being resolved via `*.homelab.local`. The commonality was the name pattern, not the services.
- **`systemctl status thanos-compact`** showed `active (running)` at every check. Only checking `/proc/<pid>/cmdline` between checks revealed the pid was churning.
- **The `NodeDown` alert itself.** The name pointed at the wrong layer (host, not application).

---

## Action Items

| Action | Owner | Status |
|---|---|---|
| Pi-hole `dns.listeningMode` -> `ALL` | Dmitry | Done |
| Uptime Kuma: migrate to compose with `extra_hosts` for `*.homelab.local` | Dmitry | Done |
| Host `resolv.conf`: add `timeout:2 attempts:3 single-request` via NetworkManager | Dmitry | Done |
| Bad Thanos block: mark `no-downsample-mark.json` | Dmitry | Done |
| R2 token: rotate to Cloudflare Account API Token, bucket-scoped, Object R/W only | Dmitry | Done |
| Alerts: narrow `NodeDown` to `up{job="node"} == 0` with `for: 5m` | Dmitry | Done |
| Alerts: add `ThanosCompactDown` (warning, 10m), `ThanosSidecarDown`/`StoreDown`/`QueryDown` (critical, 5m) | Dmitry | Done |
| Move `/etc/thanos/objstore.yml` to a secret manager (SOPS or similar) | Dmitry | Todo |
| Add alert on `dnsmasq_non_local_queries_total` if exposed by `pihole6_exporter` (or a synthetic probe from a loopback client) | Dmitry | Todo |
| Convention: alert names must describe *what* is down, not *that something* is down | Dmitry | Decided-to-adopt |

---

## Takeaways

**Silent failures are the worst kind.** Pi-hole's `logged only once` protected the disk and hid a systemic issue. Any drop, deny, or refuse operation should be counter-metered, not just log-suppressed.

**`up == 0` is not `NodeDown`.** Alert names should describe *what* is down, not just *that something* is down. Every generic "down" alert becomes noise the first time it fires on the wrong target - and every case of noise erodes trust in every future firing.

**Docker `network_mode: host` inherits every host DNS quirk.** A resolver setup that works for the host but leaves loopback in `resolv.conf` will propagate into containers as invisible-to-most, catastrophic-to-some failures. Prefer `extra_hosts` or user-defined bridge networks with explicit DNS for anything that must be reliable.

**A crash loop hidden by systemd looks like a healthy service** if you only check `systemctl status`. Always compare PIDs across two `status` checks - if it changed, you have a loop.

**One alert can conceal multiple faults.** The two-week DNS issue was masking a one-day Thanos issue. Fixing the loud one made the quiet one visible.
