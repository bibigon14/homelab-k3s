# Postmortem: sre-analytics OTLP trace export failure (secret/code drift)

**Status:** Resolved
**Severity:** Low (observability only — core job function unaffected)
**Duration of impact:** At least July 2026-07-19 through 2026-07-24 (~5+ days; likely longer, start date unconfirmed)
**Services affected:** `sre-analytics` CronJob (Cloudflare analytics → Telegram summary, daily 08:00)

## Summary

The `sre-analytics` CronJob repeatedly failed to export OpenTelemetry traces, logging the same DNS resolution error on every run:

```
Failed to export traces to alloy.monitoring.svc.cluster.local:4317, error code: StatusCode.UNAVAILABLE,
error details: errors resolving alloy.monitoring.svc.cluster.local:4317: [field:hostname lookup error:
address lookup failed ... Domain name not found]
```

A code fix was shipped, verified, and deployed on July 19. The identical error recurred on July 20 and again on July 21. The actual root cause — an imperatively-created Kubernetes Secret silently overriding the corrected code default — wasn't found until July 24.

This is a config-drift incident, not a code-quality incident: the code was correct after the first fix. The failure mode was invisible because the overriding value lived outside git, outside Helm, and outside the initial grep search pattern.

## Impact

- OTLP trace export failed on every affected run (visible in pod logs as repeated `ERROR` lines and retries).
- The core CronJob function — pulling Cloudflare zone/KV analytics and posting a Telegram summary — was **not** affected; this was purely a tracing/observability gap.
- No alerting fired on this, since it degrades observability rather than the monitored service itself (worth noting as a secondary gap — see Action Items).

## Timeline (all times Pacific)

- **Prior to July 19** — `sre-analytics` pod logs show recurring `alloy.monitoring.svc.cluster.local:4317` DNS failures on every scheduled run.
- **July 19** — Root cause investigated via live `kubectl`/Prometheus/DNS checks. Found that `sre_analytics.py`'s default `OTLP_ENDPOINT` pointed at `alloy.monitoring` — Grafana Alloy, which in this cluster has no OTLP receiver Service — instead of `tempo-distributor.monitoring`, Grafana Tempo's actual OTLP gRPC receiver on port 4317.
  - Code fixed: `OTLP_ENDPOINT` default changed to `http://tempo-distributor.monitoring.svc.cluster.local:4317` (commit `040c85b`, `fix: correct default OTLP endpoint from alloy to tempo-distributor`).
  - Verified `sre-worker` clone on the Pi (`/home/bibigon88/sre-worker`) pulled the fix, Docker image rebuilt, `k3s ctr images import`'d successfully.
  - `cronjob.yaml` and `values.yaml` in the Helm chart were grepped for `alloy`/`OTLP_ENDPOINT` — no matches. Concluded the fix was complete.
- **July 20, 08:01** — Identical `alloy.monitoring` error recurs. Initially unclear why; assumed possible propagation delay.
- **July 21, 08:01** — Same error, third occurrence. Confirms this is not a one-off.
- **July 24** — Fresh diagnostic pass:
  - `kubectl describe cronjob sre-analytics -n apps` revealed `Environment Variables from: sre-analytics-env Secret` — an `envFrom` reference, which the earlier `grep -n "env:"` search never matched (it only matches a literal `env:` key, not `envFrom:`).
  - Decoded the Secret: `OTLP_ENDPOINT` was explicitly set to `http://alloy.monitoring.svc.cluster.local:4317` — the pre-fix value.
  - `~/homelab-k3s/README.md` confirmed `sre-analytics-env` is one of several secrets "created imperatively via `kubectl create secret`" — never tracked in git, never templated by the Helm chart, invisible to any git-based search or ArgoCD sync. Created June 28, well before the OTLP endpoint bug was even diagnosed.
  - Since the application reads the endpoint via `os.environ.get("OTLP_ENDPOINT", <default>)`, an explicitly-set environment variable unconditionally wins over the code default — the July 19 fix could never have taken effect while this Secret existed.
- **July 24** — Fix applied: `kubectl patch secret sre-analytics-env -n apps --type merge -p '{"stringData":{"OTLP_ENDPOINT":"http://tempo-distributor.monitoring.svc.cluster.local:4317"}}'`. Verified via base64-decoded read. No further recurrences expected; will confirm on the next scheduled run.

## Root Cause

Two independent, stacked issues:

1. **Wrong default in code** — `sre_analytics.py` defaulted to an OTLP endpoint (`alloy.monitoring`) that was never a valid trace receiver in this cluster. (Fixed July 19.)
2. **Imperative, untracked Secret overriding the default** — `sre-analytics-env` explicitly set `OTLP_ENDPOINT` to the same wrong value. Because it was created via a one-off `kubectl create secret` command rather than through the Helm chart or GitOps, it was invisible to code review, git history, and a `grep` search scoped to `env:` instead of `envFrom:`. This is what actually caused the July 20/21 recurrence — the code fix was correct and deployed, but a second, higher-precedence source of truth silently overrode it.

The deeper root cause is process, not code: this cluster has multiple Secrets (`bridge-config`, `wc2026bot-env`, `sre-analytics-env`) that exist only as live cluster state, with no record of their contents or provenance outside the cluster itself. Any value inside them can drift from — or directly contradict — what the application code and Helm chart appear to specify.

## Resolution

- Patched `sre-analytics-env` to the correct `OTLP_ENDPOINT` value directly in-cluster.
- No image rebuild or redeploy was needed this time, since the code was already correct.

## Action Items

- [ ] **Migrate imperative Secrets to Sealed Secrets or External Secrets Operator**, so their contents are versioned in git and visible to the same review/search process as everything else. This is the systemic fix — it would have caught this drift at review time instead of five days into silent failure. *(Tracked as a separate initiative — see SLO/secrets-management writeup.)*
- [ ] When re-verifying a "fixed" config default, grep for both `env:` and `envFrom:` (and check `kubectl describe` output directly, not just chart source) — a Helm chart with no visible `env:` block can still inject conflicting values via a Secret/ConfigMap reference.
- [ ] Consider alerting on repeated OTLP export failures specifically (currently silent from an alerting standpoint — this was only caught by manually reading pod logs).
- [ ] Document in `docs/incident-response.md` under "Known gotchas": *if a code-level default fix doesn't hold, check `kubectl describe` for `envFrom`/Secret overrides before assuming the fix didn't deploy.*

## Lessons Learned

The most useful diagnostic step here wasn't in the code or the Helm chart — it was `kubectl describe cronjob`, which is the one place that shows the fully resolved pod spec, including secret references a chart's source files won't reveal by themselves. When a fix that should have worked doesn't, the next move is to look at what the cluster is *actually running*, not just what the source says it should run.
