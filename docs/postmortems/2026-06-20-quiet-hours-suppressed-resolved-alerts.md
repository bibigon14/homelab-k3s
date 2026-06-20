# Postmortem: Quiet-hours suppression dropped resolved-alert notifications, leaving operator unable to distinguish "still firing" from "auto-resolved overnight"

**Date:** 2026-06-20
**Author:** DS
**Status:** Mitigated
**Severity:** SEV-3 (no service outage; reduced alert signal quality during off-hours)
**Service affected:** `alertmanager-telegram-bridge`
**Platform:** homelab kubernetes platform

---

## Summary

The `alertmanager-telegram-bridge` service relays Prometheus Alertmanager
notifications to Telegram. To reduce off-hours noise, it implements a
"quiet hours" window (23:00–07:00 PT) during which non-critical (warning,
info) notifications are suppressed.

The implementation suppressed all non-critical traffic during the quiet window
indiscriminately: both new firing alerts and their corresponding resolved
notifications. As a result, when a warning-severity alert fired during quiet
hours and self-resolved before the window ended, the operator received no
indication of either event. On wakeup, there was no way to distinguish "this
alert is still firing and needs attention" from "this alert fired and resolved
on its own; no action needed", because in both cases the chat showed nothing.

For the operator's mental model of the system, this is worse than receiving
both notifications and worse than receiving neither: the absence of a resolve
notification, combined with the absence of a firing notification, is
indistinguishable from "nothing happened" — even when something did happen and
might still be happening.

The fix is to route `resolved` notifications around the quiet-hours filter
unconditionally, on the principle that the operational cost of "did the alert
go away or not?" is high enough to justify a single notification even during
sleep hours.

## Impact

- **Duration of design defect:** since initial deployment of the chart at
  2026-06-18 20:31 UTC; first directly observed during operator review on
  2026-06-20.
- **Concrete observed loss:** on the night of 2026-06-19/20, at least one
  `KubeJobFailed` cycle and one `KubePodNotReady` cycle related to the
  `iptv-influx-writer` CronJob fired and (apparently) self-resolved during
  the quiet window. The operator awoke to no notifications and had to manually
  query Alertmanager to confirm that no alerts were currently active.
- **No production user impact** — these are infra alerts on personal
  infrastructure. The risk pattern would have been more serious in a
  multi-operator on-call environment.

## Timeline (UTC, except where noted)

| Time | Event |
|---|---|
| 2026-06-18 20:31 | Bridge first deployed with quiet-hours configuration `enabled: true, start: "23:00", end: "07:00", timezone: "America/Los_Angeles"`. |
| 2026-06-20 05:35 | `KubeJobFailed` warning alert fires for `iptv-influx-writer-29698890`. Bridge log: `Alert KubeJobFailed → 85698759: sent`. Operator receives Telegram message. |
| 2026-06-20 05:45 | `KubePodNotReady` warning for the same workload. `Alert KubePodNotReady → 85698759: sent`. Operator receives Telegram message. |
| 2026-06-20 06:00 (= 23:00 PT) | Quiet hours begin. Alertmanager continues to send `firing` repeat notifications via webhook every `repeat_interval` (5min by default). Bridge log: `Suppressed (quiet hours): alertname=KubeJobFailed ...` and same for `KubePodNotReady`. These repeats correctly fail to wake the operator. |
| 2026-06-20 06:00 – 14:00 | Workload presumably stabilizes; Alertmanager generates `resolved` notifications. Bridge applies the same `Suppressed (quiet hours)` rule. Resolved notifications are silently dropped. |
| 2026-06-20 14:00 (= 07:00 PT) | Quiet hours end. Alerts already resolved at this point: no further notifications generated. |
| 2026-06-20 15:00–16:00 | Operator reviews logs and Telegram chat after waking up. Last visible notifications are from before the quiet window. No `resolved` notifications. Operator queries Alertmanager directly: `curl /api/v2/alerts \| jq` returns an empty list. Operator realizes the alert pipeline cannot distinguish "still firing, silenced" from "resolved, silenced". |
| 2026-06-20 16:18 | Code change drafted: in `bridge.py`'s `_process()` method, the `quiet and not is_crit` suppression check is moved after the `status == "resolved"` branch. Resolved notifications now bypass quiet-hours and throttle, and additionally clear any throttle-store entry for that fingerprint. Four regression tests added. |
| 2026-06-20 16:24 | Code fix deployed to production after resolving the [docker/containerd image-store mismatch](./2026-06-20-docker-vs-containerd-image-store.md). |
| 2026-06-20 16:34 | Fix observed working: tested by sending a synthetic resolved-warning webhook during the daytime (not in quiet hours) and confirmed the codepath was exercised in tests; full overnight validation pending the next nightly cycle. |

## Root cause

The bridge's `_process()` method evaluated quiet-hours suppression unconditionally
for non-critical alerts, before considering whether the notification was a
new firing or a resolution of an existing one:

```python
# Before (buggy):
for alert in alerts:
    ...
    if quiet and not is_crit:
        log.info("Suppressed (quiet hours): %s", fp)
        continue                          # drops resolved alerts too

    if status == "firing":
        ...
    elif status == "resolved":
        ...
```

The single `if quiet and not is_crit: continue` short-circuited both branches.
There was no distinction between "new noisy thing happening" (legitimate
quiet-hours target) and "previously noisy thing is no longer happening"
(operationally important).

## Contributing factors

1. **Design assumption baked in at chart creation.** The chart was written with
   the implicit assumption that "suppression of noise" applied equally to all
   notifications. There is no design document or comment explaining the
   intended treatment of resolved alerts.
2. **No alert-loop integration test.** Tests cover individual functions
   (`is_quiet_hours`, `ThrottleStore`, `format_alert`, `BotCommandHandler`)
   but not the end-to-end firing→resolved flow with quiet-hours applied.
3. **Asymmetry-of-information bias.** Operator originally tested by sending
   a `firing` payload, observed it was correctly suppressed, and stopped.
   Did not test that the corresponding `resolved` would behave correctly.
4. **Symptom-free during waking hours.** Outside the quiet window, all
   notifications flowed normally. The defect was only observable during the
   8-hour overnight window, when the operator was not watching.

## Detection

The bug was self-reported by the operator after reviewing logs from the
previous night. Specifically:

1. Observation: Telegram chat last message was a `firing` from before quiet
   hours started; no follow-up.
2. Hypothesis A: the alert was still firing → falsified by `curl
   /api/v2/alerts` returning empty.
3. Hypothesis B: the resolve happened but was dropped → confirmed by
   `kubectl logs deploy/bridge | grep -E 'KubeJobFailed|KubePodNotReady'`
   showing `Suppressed (quiet hours)` entries spanning hours, with no
   `→ sent` for the resolved status anywhere.

The bridge was logging the correct information; the operator just needed to
notice that "Suppressed" included resolves. No alerting on the alerting
pipeline existed (a common gap in any monitoring setup).

## What helped

- **Bridge logs every suppression decision with full label set.** Made the
  postmortem timeline trivially reconstructable.
- **Querying `/api/v2/alerts` directly to distinguish "still firing" from
  "resolved".** This is the source-of-truth check; should be the first step
  whenever Telegram looks suspiciously quiet.

## What did not help

- **Reading the Alertmanager UI.** Showed currently-active alerts only; said
  nothing about what happened overnight.
- **Trusting the absence of notification.** Default-deny on alerting is the
  whole problem here.

## Action items

| # | Action | Owner | Status |
|---|---|---|---|
| 1 | Move the `status == "resolved"` check before the quiet-hours suppression check in `bridge.py:_process()`. Resolved notifications bypass quiet hours unconditionally. | DS | Done (`bibigon14/alertmanager-telegram-bridge` commit `3ced951`) |
| 2 | Add regression tests for the four key cases: warning-resolved-in-quiet-hours, warning-firing-in-quiet-hours, critical-firing-in-quiet-hours, resolved-clears-throttle-store. | DS | Done (same commit, `test_bridge.py`) |
| 3 | Document the quiet-hours design intent: "quiet hours suppresses non-critical *firing* notifications; *resolved* notifications always flow." Add to chart README. | DS | Todo |
| 4 | Export Prometheus metrics from the bridge: `bridge_telegram_sent_total{status,severity}`, `bridge_alerts_suppressed_total{reason}`. Allows an alert on "suppression rate > 0 for resolved status" to detect this exact regression class in the future. | DS | Todo |
| 5 | Add a self-healing canary: every morning at 07:05 PT, the bridge sends a heartbeat to itself, exercising the full path. If skipped, an external check (Uptime Kuma) notices. | DS | Todo |
| 6 | Consider replacing the in-process quiet-hours filter with Alertmanager's native `time_intervals` + `mute_time_intervals` / `active_time_intervals` routing. This pushes the filter upstream to the system designed for it, removes a custom code path, and inherits Alertmanager's already-correct handling of resolved notifications during muted intervals. | DS | Todo (decide via ADR) |

## Takeaways

- **Suppression should default to "firing only"**, not to "all traffic". The
  cost of one extra Telegram message at 03:00 saying "the warning resolved"
  is much lower than the cost of waking up uncertain whether something is
  still broken.
- **Tests on a notification pipeline must cover both firing and resolved
  flows for each route.** Symmetric inputs do not imply symmetric outputs;
  testing one direction proves nothing about the other.
- **"No Telegram message" carries no information by default.** Either it's
  fine, or the alert was filtered, or the bot is broken, or the network is
  down. A pipeline that cannot self-attest to "still alive and routing
  correctly" creates ambiguity exactly at the moments it matters most.
- **When designing custom filters that sit between Alertmanager and the
  delivery channel, ask: "what does Alertmanager already provide for this?"**
  Native `time_intervals` would have come with the correct behavior for free.
  Reimplementing this in a relay was a small piece of avoidable scope.
