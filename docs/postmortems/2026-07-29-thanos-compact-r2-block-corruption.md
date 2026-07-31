# Postmortem: Thanos Compact Corruption Recurs - Four New R2 Blocks Fail Checksum Validation, One Crash Loop Exhausts Restart Limit

**Date:** 2026-07-29 to 2026-07-30 | **Duration:** ~24 hours (intermittent, across 4 new corruption events plus rediscovery of one previously-known bad block) | **Severity:** SEV-2
**Author:** Dmitry Stepanov | **Status:** Resolved (mitigated) — root cause still open

---

## Summary

`thanos-compact` repeatedly halted or crash-looped after encountering four newly-corrupted blocks in the R2-backed `homelab-thanos` bucket, each failing chunk- or index-level checksum validation during compaction or downsampling. A fifth block flagged during cleanup, `01KXMPW4MTXD4ZY1KKT8BT3XTH`, turned out not to be new: it's the same block from the [2026-07-18 postmortem](./2026-07-18-postmortem-pihole-loopback-drop-thanos-cascade.md), which had been marked `no-downsample-mark.json` (excluded from downsampling, raw data preserved) rather than deleted. This is the second Thanos-compact corruption incident in 11 days, and the underlying cause of the corruption itself — flagged as unresolved in the July 18 postmortem — is still unconfirmed. Three of four new blocks were only discovered reactively via crash; one was found proactively via a manual `thanos tools bucket verify` scan, which is also what surfaced the July 18 block again.

---

## Impact

- **User/application impact:** None. All production homelab services (river-bot, wc2026bot, iptv monitoring, Grafana, Prometheus scraping) continued operating normally throughout.
- **Service impact:** `thanos-compact.service` reached a hard `failed` state (systemd `StartLimitBurst` exhausted, "manual intervention required") for ~40 minutes.
- **Data impact:** 2 of 4 new blocks (`01KYKKH55SM5YNAT5JEW0K57MZ`, `01KYRRDVXTT49W7T75004FZ93M`) permanently deleted — unrecoverable, ~2h of raw metrics each. 1 new block (`01KYNX157SEAWJG16X7QY27JKB`) salvaged via compaction into a healthy merged block, no data loss. 1 new block (`01KYQ67GQRSQ3J13ZPJQ9JNEGX`) marked `no-compact` only — raw data preserved, just excluded from further compaction/downsampling. The rediscovered July 18 block (`01KXMPW4MTXD4ZY1KKT8BT3XTH`) was upgraded from `no-downsample-mark.json` to `deletion-mark.json` and physically deleted — it had already been excluded from 5m/1h downsampling for 12 days, so the incremental loss is the raw block itself.
- **Observability impact:** 5m/1h downsampling fell behind for ~24 cumulative hours across the incident window.
- **Cost impact (side effect, same session):** R2 storage reached 11.44 GB against the 10 GB free-tier threshold, driven by a backlog of already-superseded blocks stuck behind the default 48h `--delete-delay` that had never been cleaned up — not by this incident's corruption directly. Resolved same session (bucket down to 1.98 GB after backlog flush).

---

## Timeline

All times UTC.

| Time (UTC) | Event |
|------------|-------|
| ~2026-07-29 13:xx (approx., before investigation began) | `ThanosCompactHalted` [CRITICAL] first fires — block `01KYNX157SEAWJG16X7QY27JKB` checksum mismatch (chunk 4538110) halts compaction. |
| 15:02 | Alert auto-resolves after remediation begins. |
| 15:02–15:15 | Block 1 (`01KYNX157SEAWJG16X7QY27JKB`) marked `no-compact`; compaction succeeds, block salvaged via merge. Block 2 (`01KYKKH55SM5YNAT5JEW0K57MZ`) discovered during downsampling — `no-compact` mark insufficient (downsampling ignores it); resolved via `deletion-mark` + temporary `--delete-delay=0s`. `thanos_compact_halted` confirmed 0 at 15:15. |
| 21:34:47 | Block 3 (`01KYQ67GQRSQ3J13ZPJQ9JNEGX`) checksum mismatch (chunk 10174295) during compaction of group `0@16166741704735203456` — compactor halts gracefully (process stays alive, `thanos_compact_halted=1`, no crash/restart). |
| 21:40 onward | `ThanosCompactHalted` fires and re-notifies hourly per Alertmanager `repeat_interval` (21:40, 22:45, 23:50, 2026-07-30 00:55) — not noticed in real time. |
| 2026-07-30 01:50 | Incident noticed via Telegram alert history while investigating an unrelated Grafana issue. |
| 02:04–02:09 | Block 3 marked `no-compact`, compactor restarted, full compact→downsample→retention cycle completes cleanly. `TimeoutStopSec=300` and corrected `StartLimitIntervalSec=600`/`StartLimitBurst=5` (previously silently ignored — misplaced in `[Service]` instead of `[Unit]`) added to the systemd unit. |
| 06:29–06:31 | Block 4 (`01KYRRDVXTT49W7T75004FZ93M`) checksum mismatch (chunk 10305515) during downsampling — the compactor **exits** (fatal error path) rather than halting gracefully, triggering systemd's `Restart=on-failure` loop. Restart counter reaches 11 within 600s; the newly-enforced `StartLimitBurst=5` correctly stops the loop, leaving `thanos-compact.service` in `failed` state. |
| 06:33 | `ThanosCompactFailed` [CRITICAL] fires: "Thanos Compactor has hit StartLimitBurst and stopped restarting. Manual intervention required." |
| 07:13 | Incident noticed via Telegram. |
| 07:16 | `systemctl reset-failed`; block 4 marked `deletion-mark`; temporary `--delete-delay=0s`; restart. Compaction succeeds; ~20 previously-superseded blocks (unrelated backlog stuck behind the default 48h delete-delay) flush in the same cleanup pass. |
| 07:19 | Proactive `thanos tools bucket verify -i index_known_issues` run against the full bucket (14 remaining blocks) to catch any further corruption before it could cause another halt. Flags `01KXMPW4MTXD4ZY1KKT8BT3XTH` — index series checksum invalid. Later identified as the same block from the 2026-07-18 postmortem, not a new corruption. |
| 07:20–07:21 | `01KXMPW4MTXD4ZY1KKT8BT3XTH` upgraded from `no-downsample-mark.json` (July 18) to `deletion-mark.json` and cleaned up. Full cycle completes cleanly. `--delete-delay=0s` reverted to default. |
| 07:22 | R2 dashboard still showing 11.44 GB (reporting lag). |
| ~07:26 | `--retention.resolution-1h` reduced 180d → 90d (unrelated storage-headroom decision, made same session while diagnosing the R2 growth). |
| ~07:35 | R2 dashboard refreshes: `homelab-thanos` bucket down from 11.11 GB to 1.98 GB once the backlog cleanup and reporting lag caught up. |

---

## Root Cause

**Not confirmed — same open question as 2026-07-18, now with a second data point.** Four new independent chunk/index checksum-mismatch corruptions occurred in R2-stored blocks within a 24-hour window, less than two weeks after the previous incident's corrupted block (`01KXMPW4MTXD4ZY1KKT8BT3XTH`) was found and only partially mitigated (marked `no-downsample-mark.json` rather than removed). NVMe SMART health (`Critical Warning: 0x00`, `Media and Data Integrity Errors: 0`, `Percentage Used: 0%`) and `dmesg` showed no hardware-level storage or memory errors, ruling out local disk/RAM failure.

**Leading hypothesis, unchanged from July 18:** an interrupted upload to R2 — either from network instability or from the compactor process being forcefully terminated mid-write/mid-upload — produces a block that passes the initial write but fails checksum validation when read back later. This session directly observed systemd SIGKILLing `thanos-compact` on restart (default `TimeoutStopSec` too short), which is a plausible *contributing* mechanism, but doesn't explain the July 18 corruption, which predates any of this session's restarts. The recurrence after 11 days, with a different set of block IDs, suggests either an ongoing environmental issue (R2 upload reliability, Pi network stability) or a latent bug in the Thanos version's block-writing path — not a one-off fluke.

**Still not done:** reviewing Prometheus/sidecar upload logs and Pi→R2 network stability around each corruption event. This was an action item after July 18 too (implicitly, under "move objstore config to a secret manager") and was never actually pursued — carried forward explicitly this time.

---

## Contributing Factors

- **`StartLimitIntervalSec`/`StartLimitBurst` were silently ignored by systemd** (wrong section — `[Service]` instead of `[Unit]`) since at least July 18, meaning any crash loop before this incident would have restarted forever without ever escalating to a hard failure or a distinct alert.
- **Default `TimeoutStopSec` (~90s) was too short**, causing systemd to SIGKILL `thanos-compact` on manual restarts during this session — a plausible corruption vector that wasn't in place as a hardening measure after July 18.
- **No proactive corruption scanning.** `thanos tools bucket verify` exists and is cheap to run, but wasn't scheduled after July 18 despite that incident explicitly involving undetected block corruption. It caught 1 of 5 blocks proactively this time only because it was run manually mid-incident.
- **The July 18 fix for `01KXMPW4MTXD4ZY1KKT8BT3XTH` was a mitigation, not a resolution** — `no-downsample-mark.json` stops downsampling from touching the block but leaves it in the bucket indefinitely, still discoverable (and still corrupted) by any later scan or compaction attempt.
- **Default 48h `--delete-delay`** allowed a large, invisible backlog of already-superseded (healthy, not corrupted) blocks to accumulate in R2, which was the primary driver of the same-session R2 storage scare — a separate but compounding issue that made the bucket harder to reason about during triage.

---

## What Helped

- Alerting caught every occurrence of the new corruption (Telegram, via Alertmanager `ThanosCompactHalted`/`ThanosCompactFailed`) — a direct improvement over July 18, where the crash loop was initially invisible under generic `NodeDown` noise before the dedicated Thanos alerts (added as a July 18 action item) existed.
- A repeatable remediation pattern (mark `no-compact` or `deletion-mark` → temporarily zero `--delete-delay` if needed → restart → verify `thanos_compact_halted`) was established on the first block and reused efficiently for the rest.
- Proactively running `thanos tools bucket verify` caught the rediscovered July 18 block before it could cause another outage, and gave enough confidence to close out the remaining bucket as clean.
- Hardware (NVMe, memory) was ruled out quickly and conclusively via SMART and `dmesg`.
- Systemd unit hardening (`TimeoutStopSec=300`, corrected `StartLimitIntervalSec`/`StartLimitBurst`) was identified and fixed in the same session.

## What Did Not Help

- Checking `systemctl status thanos-compact` alone during the graceful-halt window (21:34–01:50) would have shown `active (running)` the whole time — same blind spot called out in the July 18 postmortem ("a crash loop hidden by systemd looks like a healthy service"), except this time it was a *halt* hidden behind a healthy-looking process rather than a crash loop.
- The July 18 mitigation for `01KXMPW4MTXD4ZY1KKT8BT3XTH` (`no-downsample-mark.json` instead of deletion) meant the same known-bad block was still sitting in the bucket 11 days later, waiting to be rediscovered rather than actually resolved.
- No secondary escalation beyond a single Telegram channel for the hard-`failed` state — it sat unnoticed for ~40 minutes (06:33 → 07:13).

---

## Action Items

| Action | Owner | Status |
|---|---|---|
| Mark/delete all 4 newly-corrupted blocks + rediscovered July 18 block | Dmitry | Done |
| `TimeoutStopSec=300` on `thanos-compact.service` | Dmitry | Done |
| Fix `StartLimitIntervalSec`/`StartLimitBurst` placement (`[Unit]`, not `[Service]`) | Dmitry | Done |
| Reduce `--retention.resolution-1h` 180d → 90d (R2 storage headroom) | Dmitry | Done |
| Document Thanos retention + systemd hardening in `homelab-observability` README | Dmitry | Done |
| Investigate actual root cause: Prometheus/sidecar upload logs + Pi→R2 network stability around each corruption event (carried over, unaddressed since 2026-07-18) | Dmitry | Todo |
| Schedule `thanos tools bucket verify -i index_known_issues` as a periodic (weekly) job instead of relying on reactive discovery or manual runs | Dmitry | Todo |
| When mitigating a corrupted block going forward, prefer `deletion-mark` over `no-downsample-mark` unless there's a specific reason to keep the raw data around — the July 18 mitigation left a known-bad block to be rediscovered 11 days later | Dmitry | Decided-to-adopt |
| Add a stronger escalation path for `ThanosCompactFailed` (hard-failed, manual-intervention-required state) beyond a single Telegram message | Dmitry | Todo |
| Reconsider default `--delete-delay` (currently 48h) to reduce backlog-accumulation risk | Dmitry | Todo |

---

## Takeaways

**A mitigation that leaves the bad data in place isn't a resolution.** `no-downsample-mark.json` on `01KXMPW4MTXD4ZY1KKT8BT3XTH` stopped the bleeding on July 18 but didn't fix anything — the corrupted block just sat there until it was rediscovered 11 days later. When the underlying cause of corruption is unconfirmed, prefer removing the bad data outright (or explicitly tracking it as a known-open item) over a mark that makes it invisible to normal operation but still present.

**A graceful halt is exactly as hard to notice as a crash loop, for a different reason.** July 18's lesson was "a crash loop hidden by systemd looks like a healthy service." This incident's version: a process that halts on purpose and keeps its HTTP server up looks *identical* to a healthy one from `systemctl status`. Both failure modes need to be caught by watching the actual signal (`thanos_compact_halted`, or PID churn) — not by trusting systemd's own view of "running."

**Recurrence within 11 days means the first postmortem's root-cause action item was real, not optional.** "Root cause unknown, revisit later" is a valid outcome of a first incident. Not revisiting it before the second one is where it becomes a process failure, not just a technical one.
