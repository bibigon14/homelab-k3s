# Postmortem: sre-analytics OTLP trace export silently broken by an untracked Secret overriding a corrected code default

**Date:** 2026-07-19 – 2026-07-24
**Author:** DS
**Status:** Resolved
**Severity:** SEV-3 (degraded signal quality — tracing telemetry only, no outage of the monitored job)
**Services affected:** `sre-analytics` CronJob (`apps` namespace)
**Platform:** homelab kubernetes platform (k3s, single node, ArgoCD-managed)

---

## Summary

The `sre-analytics` CronJob (daily Cloudflare zone/KV analytics → Telegram summary, 08:00 PDT) repeatedly failed to export OpenTelemetry traces, logging the same DNS resolution error on every run:

```
Failed to export traces to alloy.monitoring.svc.cluster.local:4317, error code: StatusCode.UNAVAILABLE,
error details: errors resolving alloy.monitoring.svc.cluster.local:4317: [field:hostname lookup error:
address lookup failed ... Domain name not found]
```

On 2026-07-19 the apparent root cause was found and fixed in code: `sre_analytics.py` defaulted `OTLP_ENDPOINT` to Grafana Alloy, which has no OTLP receiver in this cluster, instead of Tempo's `tempo-distributor`. The fix was committed, the image was rebuilt on the Pi, and re-imported into k3s. The identical error recurred on both 07-20 and 07-21.

The actual root cause, found 2026-07-24, was a second and higher-precedence source of truth: `sre-analytics-env`, a Secret created imperatively via `kubectl create secret` on 2026-06-28, had `OTLP_ENDPOINT` hardcoded to the pre-fix Alloy address. It was never tracked in git or the Helm chart, so it was invisible to code review and to a `grep -n "env:"` search that didn't account for `envFrom:`. Because the app reads the endpoint via `os.environ.get("OTLP_ENDPOINT", <default>)`, the Secret's explicit value unconditionally won over the corrected default — the July 19 fix could never have taken effect while it existed.

This is the second incident in five weeks with the same underlying shape as [2026-06-20-argocd-secret-data-overwrite.md](./2026-06-20-argocd-secret-data-overwrite.md): a Secret that exists only as live cluster state, outside git, silently determining application behavior in a way no amount of source review can catch.

## Impact

- OTLP trace export failed on every affected `sre-analytics` run from at least 2026-07-19 (likely earlier — first-occurrence date unconfirmed) through 2026-07-24.
- The CronJob's core function — pulling Cloudflare analytics and posting the Telegram summary — was **not** affected. This was purely a tracing/observability gap: `sre-analytics` traces were absent from Tempo for the entire window.
- No alert fired. This class of failure degrades observability rather than the monitored service itself, so it was only caught by manually reading pod logs — twice, on two separate days, before the actual cause was identified.

## Timeline (UTC)

| Time | Event |
|---|---|
| 2026-07-19 (date only; exact time not logged) | `sre-analytics` pod logs show recurring `alloy.monitoring.svc.cluster.local:4317` OTLP export failures on the scheduled run. |
| 2026-07-19 | Root cause investigated via live `kubectl`/Prometheus/DNS checks. Confirmed Alloy has no OTLP receiver Service in this cluster; Tempo's `tempo-distributor` is the actual gRPC receiver on :4317. |
| 2026-07-19 | Code fixed: `sre_analytics.py` default `OTLP_ENDPOINT` changed to `http://tempo-distributor.monitoring.svc.cluster.local:4317` (commit `040c85b`). |
| 2026-07-19 | `sre-worker` clone on the Pi pulled, Docker image rebuilt, `k3s ctr images import`'d. `cronjob.yaml`/`values.yaml` in the Helm chart grepped for `alloy`/`OTLP_ENDPOINT` — no matches. Fix assumed complete. |
| 2026-07-20 15:01 | Identical `alloy.monitoring` DNS failure recurs on the 08:00 PDT scheduled run. |
| 2026-07-21 15:01 | Same failure, third occurrence. Confirms this is not transient/propagation-delay. |
| 2026-07-24 15:50 | Fresh diagnostic pass. `kubectl describe cronjob sre-analytics -n apps` shows `Environment Variables from: sre-analytics-env Secret` — an `envFrom` reference the earlier `grep -n "env:"` never matched. |
| 2026-07-24 15:58 | Secret decoded: `OTLP_ENDPOINT` explicitly set to the pre-fix `alloy.monitoring` value. `homelab-k3s/README.md` confirms `sre-analytics-env` was created imperatively via `kubectl create secret` on 2026-06-28 — never templated by the chart, never in git. |
| 2026-07-24 16:00 | Fix applied: `kubectl patch secret sre-analytics-env -n apps --type merge -p '{"stringData":{"OTLP_ENDPOINT":"http://tempo-distributor.monitoring.svc.cluster.local:4317"}}'`. Verified via base64-decoded read. |

## Root cause

**An imperatively-created Secret, invisible to git and to the chart, held an explicit `OTLP_ENDPOINT` value that unconditionally overrode a corrected code default.** `os.environ.get(key, default)` only falls back to `default` when the key is entirely absent from the process environment — a stale-but-present value always wins, regardless of how correct the code's own default is.

The July 19 fix was real and necessary (Alloy genuinely isn't a valid OTLP target here) but incomplete: it addressed the code-level symptom without surfacing the Secret that was actually driving runtime behavior, because nothing in the chart source referenced it by a name the initial search covered.

## Contributing factors

1. **Search pattern missed `envFrom:`.** `grep -n "env:"` against `cronjob.yaml`/`values.yaml` is a reasonable first check but only matches a literal `env:` key — it does not match `envFrom:`, which is how this Secret was actually wired in.
2. **Same untracked-Secret anti-pattern as the 2026-06-20 incident**, not yet remediated. `bridge-config` and `wc2026bot-env` were fixed and documented five weeks ago; that postmortem's action item to audit all charts for the same pattern (#4) had not been extended to `sre-analytics-env`, likely because this Secret isn't templated by any chart at all — there was no chart resource to audit in the first place, only a manually-run `kubectl create secret`.
3. **No drift detection between "what the code assumes" and "what's actually injected.**" There is no step in the deploy or verification process that diffs the live pod's resolved environment against the source of truth in git.
4. **No alerting on repeated OTLP export failures.** The recurrence sat for two extra days (07-20 → 07-21) before it registered as a pattern rather than a one-off; there is no self-monitoring signal for the telemetry pipeline itself.

## What helped

- **`kubectl describe cronjob sre-analytics -n apps`** — the one place that shows the fully resolved pod spec, including `envFrom` Secret references that chart source files alone don't reveal. This is what actually broke the investigation open on 07-24.
- **Decoding the Secret directly** and comparing it against the intended value, rather than trusting that "the chart doesn't mention it" meant "nothing overrides it."

## What did not help

- **Grepping only chart source files for `env:`/`alloy`.** Technically executed correctly, but the wrong search surface — it can't find values injected via `envFrom` from a Secret the chart doesn't even declare.
- **Treating a successful Docker rebuild + `k3s ctr images import` as confirmation the fix was fully deployed.** That closes the loop for a code-level default; it says nothing about cluster-level Secret overrides sitting on top of it.

## Action items

| # | Action | Owner | Status |
|---|---|---|---|
| 1 | Migrate `sre-analytics-env` to Sealed Secrets or External Secrets Operator, so its contents are versioned and reviewable like everything else | DS | Todo |
| 2 | Extend the 2026-06-20 postmortem's Secret audit (action item 4) to explicitly include `sre-analytics-env` and confirm no other CronJob-scoped Secret follows the same untracked pattern | DS | Todo |
| 3 | Standardize on `kubectl describe`/`kubectl get -o yaml` on the live resource as the first diagnostic step when a "confirmed" fix doesn't hold — not chart source grep | DS | Done (this document) |
| 4 | Add alerting on repeated OTLP export failures from `sre-analytics` (or CronJobs generally) so recurrence is caught without manually reading logs | DS | Todo |
| 5 | Document in `docs/incident-response.md` under "Known gotchas": if a code-level default fix doesn't hold, check `envFrom`/Secret overrides before assuming the fix didn't deploy | DS | Todo |

## Takeaways

- Chart/manifest source review is necessary but not sufficient. `kubectl describe`/`get -o yaml` against the live resource is the only ground truth for what's actually injected into a pod — grep against git only tells you what git knows about.
- This is the second incident in five weeks caused by the same underlying pattern: an imperative, git-invisible Secret silently overriding intended configuration. The systemic fix identified after the first occurrence (migrate to Sealed Secrets / External Secrets Operator) has not yet been implemented; this incident is further evidence it should be prioritized rather than re-diagnosed case by case.
- An environment-variable default in code is only as trustworthy as the assumption that nothing else in the cluster is injecting the same key. Treat "the code has a sane default" and "the pod will actually receive that default" as two separate claims that both need verifying.
