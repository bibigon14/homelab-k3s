# Postmortem: Telegram alert delivery silently broken by ArgoCD overwriting Secret data

**Date:** 2026-06-20
**Author:** DS
**Status:** Mitigated
**Severity:** SEV-2 (alert pipeline blind, no user-visible outage of monitored services)
**Services affected:** `alertmanager-telegram-bridge`, `wc2026bot` (both in `homelab` namespace)
**Platform:** homelab kubernetes platform (k3s, single node, ArgoCD-managed)

---

## Summary

For an unknown period leading up to 2026-06-20, the `bridge-config` Secret in the
`homelab` namespace had its `telegram.token` field silently overwritten from a
valid bot token to an empty string. The `alertmanager-telegram-bridge` pod that
was running at the time had loaded the token into memory at process start and
continued to send Telegram messages successfully, so the breakage was invisible
until the pod restarted as part of an unrelated code deploy at 2026-06-20
07:46 UTC. After the restart the bridge began logging `HTTP Error 404: Not Found`
on every Telegram API call (the API endpoint URL contains the token, and an
empty token produces a 404). Alert notifications stopped flowing entirely until
the Secret was manually repopulated and the chart was restructured to prevent
ArgoCD from rewriting it on future syncs.

The same root cause — and the same data-loss pattern — was found in
`wc2026bot-env` later in the day. That Secret was repopulated and patched in
the same way.

## Impact

- **Duration of full outage:** ~5h45m (2026-06-20 07:46 UTC → 13:18 UTC for
  bridge; ~10 minutes for wc2026bot, which was caught early because the bridge
  fix had already trained the operator to look for this pattern).
- **Alerts lost:** unknown lower bound; at least one `KubePodNotReady`
  resolution and one `KubeJobFailed` resolution did not reach Telegram during
  the 23:00-07:00 PDT quiet-hours window (separately tracked in
  [quiet-hours postmortem](./2026-06-20-quiet-hours-suppressed-resolved-alerts.md)).
- **wc2026bot:** all bot commands (`/today`, `/schedule`, `/next`, `/standings`,
  `/live`) unavailable for ~10 minutes; one scheduled match-reminder window
  affected.
- **User trust:** the bridge had been silently degraded for at least 12h
  (since the previous quiet-hours cycle); operator confidence in "no alerts =
  nothing broken" was reduced.

## Timeline (UTC)

| Time | Event |
|---|---|
| 2026-06-18 20:31 | `bridge-config` Secret created by initial Helm/ArgoCD deploy (`creationTimestamp: 2026-06-18T20:31:55Z`). Chart template renders Secret from `.Values.config.telegram.token`, which is empty in `values.yaml` (real secrets cannot live in git). |
| 2026-06-18 20:44 | `wc2026bot-env` Secret created the same way; same empty-by-default values. |
| 2026-06-18, sometime later | Operator manually patches both Secrets with real values (via `kubectl edit secret` or `kubectl apply` of a non-git-tracked manifest). Pods load values into memory and operate normally. |
| Unknown date | ArgoCD `Application` for `bridge` is later annotated with `ignoreDifferences: [{kind: Secret, jsonPointers: [/data]}]`. Operator believes this protects the Secret from being overwritten. (This belief is incorrect; see contributing factors.) |
| Unknown date | ArgoCD performs at least one sync of the `bridge` Application for a reason unrelated to the Secret (likely picking up an unrelated chart change). The sync reapplies the rendered manifest, including the empty-string Secret values. `ignoreDifferences` suppresses the `OutOfSync` UI signal but does not prevent the underlying apply. The running pod is unaffected: it loaded the token at startup. |
| 2026-06-20 07:46 | Operator restarts the `bridge` Deployment (`kubectl rollout restart deploy/bridge -n homelab`) as part of a code-fix deploy for an unrelated bug (see [quiet-hours postmortem](./2026-06-20-quiet-hours-suppressed-resolved-alerts.md)). |
| 2026-06-20 07:46 | New pod starts. `load_config()` reads empty token. First Telegram API call returns `HTTP Error 404: Not Found` (URL is `https://api.telegram.org/bot/getMe`, no token). Bridge log floods with 404s. |
| 2026-06-20 08:19 | Operator checks bridge logs after deploy verification, sees flood of 404s, begins investigation. |
| 2026-06-20 08:20 | `kubectl exec ... cat /config/config.yaml` confirms `token: ""`. |
| 2026-06-20 08:23 | `kubectl get secret bridge-config -o yaml` confirms both `data.config.yaml` (live) and `metadata.annotations.kubectl.kubernetes.io/last-applied-configuration` (recorded apply) have empty token. |
| 2026-06-20 08:25 | First mitigation attempt: `kubectl apply` of a generated Secret with real token. Apply succeeds. Pod restart re-reads, still shows empty token. Mitigation failed. |
| 2026-06-20 08:30 | Investigation confirms `ignoreDifferences` is present on the live ArgoCD Application (matches what's in git) but does not prevent reapply. Hypothesis formed: ArgoCD reapplies the rendered manifest on any sync, regardless of `ignoreDifferences`, which is purely a UI/diff-trigger filter. |
| 2026-06-20 08:45 | Git commit `f4eb131` adds `argocd.argoproj.io/sync-options: Prune=false` annotation to Secret template in chart. Pushed. |
| 2026-06-20 09:15 | Git commit `0e14844` removes `secret.yaml` from chart templates entirely. Pushed. ArgoCD picks up the change, Secret leaves desired state, but does not get pruned thanks to the annotation (`requiresPruning: true, status: OutOfSync` but object remains). |
| 2026-06-20 09:18 | Operator repopulates Secret manually with `kubectl create secret ... --dry-run=client -o yaml \| kubectl apply -f -`. Pod restart picks up the real token. `getMe` returns `ok:true`. Bridge recovers. |
| 2026-06-20 16:46 | While testing a separate code change, `wc2026bot` pod is restarted and crashes with `Fill in BOT_TOKEN, CHAT_ID and FOOTBALL_API_KEY in .env file!`. Same investigation path applied; same overwrite confirmed in `wc2026bot-env`. |
| 2026-06-20 16:53 | Same `Prune=false` + chart-template-removal fix applied to `wc2026bot` chart in git commits `108cb12` and `5f4ec17`. |
| 2026-06-20 17:00 | `wc2026bot-env` repopulated from on-disk `.env` file; bot recovers. |

## Root cause

**ArgoCD's `ignoreDifferences` suppresses drift in the UI but does not prevent
the underlying manifest from being reapplied during sync.** The chart for both
affected services rendered a Secret with empty string values pulled from
`Values.*`, because the real secret values cannot live in git. As long as no
sync occurred, the manually-patched live Secret retained its real values. Any
sync — including syncs triggered by unrelated changes to other resources in the
same Application — would re-render the chart and reapply the Secret with empty
values, silently overwriting the real data.

This was not detectable in the ArgoCD UI because `ignoreDifferences` was
configured to ignore `/data` on Secrets, so the UI never reported an
`OutOfSync` state for that field.

## Contributing factors

1. **Misunderstanding of `ignoreDifferences` semantics.** Several public ArgoCD
   tutorials and GitOps blog posts describe `ignoreDifferences` as "preventing
   ArgoCD from touching this field". The actual behavior is "preventing this
   field from appearing in the diff that determines sync status and selfHeal
   triggers". The underlying `kubectl apply` invocation during a sync still
   contains the full rendered manifest.
2. **Symptom-free degradation.** Because both processes load config into memory
   at startup, the Secret could be in a broken state on disk for an arbitrary
   period without any user-visible signal. The only triggers for visible
   failure were process restarts.
3. **Lack of an integration test or canary that exercises the live config
   path.** A 30-second health check that calls `getMe` against Telegram and
   asserts `ok: true` would have surfaced the empty token within one
   livenessProbe cycle of any restart.
4. **Single-operator environment with manual Secret management.** The standard
   GitOps story for this problem — Sealed Secrets, External Secrets Operator,
   SOPS — was never implemented because the homelab has a single operator and
   the manual `kubectl apply` flow felt acceptable. It is acceptable only as
   long as no other process reapplies the resource.
5. **`creationTimestamp` did not change despite overwrites.** When investigating,
   the operator initially used Secret age (`AGE 35h`) as evidence that "nobody
   touched this Secret recently". This was wrong: `creationTimestamp` reflects
   when the object was created, not when its data was last mutated.
   `resourceVersion` and `managedFields` would have been more reliable signals
   but were not consulted until later.

## What helped

- **Cross-referencing `data` vs `last-applied-configuration` annotation.** Both
  fields showed empty token, which proved this was not a partial update — it
  was a full reapply with empty data.
- **Reading the chart template directly.** Confirming that `secret.yaml`
  unconditionally renders `token: "{{ .Values.config.telegram.token }}"` made
  the failure mode obvious once the apply-vs-diff semantics were understood.
- **Removing the resource from chart desired state + `Prune=false`.** The
  combination is robust: ArgoCD no longer knows about the object, but cannot
  delete it either if a future change reintroduces it as managed.

## What did not help

- **`ignoreDifferences` alone.** Confirmed not sufficient.
- **`kubectl apply` immediately followed by pod restart, repeated.** This is
  the natural reflex, but on this platform it races against ArgoCD's reconciler
  loop. Several attempts succeeded transiently and then reverted.
- **Looking at `creationTimestamp`.** Misleading; see contributing factor 5.

## Action items

| # | Action | Owner | Status |
|---|---|---|---|
| 1 | Add `argocd.argoproj.io/sync-options: Prune=false` to `bridge-config` Secret template | DS | Done (git `f4eb131`) |
| 2 | Remove `secret.yaml` from `bridge` chart templates; manage Secret imperatively | DS | Done (git `0e14844`) |
| 3 | Same two changes for `wc2026bot-env` Secret | DS | Done (git `108cb12`, `5f4ec17`) |
| 4 | Audit all other charts under `homelab-k3s/charts/` for `Secret` templates that render values from git-tracked `values.yaml`. Migrate any matches to the same pattern. | DS | Todo |
| 5 | Add a startup-time `getMe` health assertion in `bridge.py` — if the bot's own identity check fails, exit with a non-zero status so the pod enters CrashLoopBackOff and the failure is visible as a pod condition, not as a quiet log line. | DS | Todo |
| 6 | Evaluate External Secrets Operator (ESO) with a local provider (e.g. a file backend or 1Password Connect) for a long-term GitOps-clean solution. Document the decision either way as an ADR. | DS | Todo |
| 7 | Add a Prometheus alert `BridgeNoTelegramTrafficInLastHour` based on a bridge-exported counter `bridge_telegram_sent_total`. If the rate drops to zero for >1h during business hours, alert. (Self-monitoring.) | DS | Todo |
| 8 | Document this failure mode in the `homelab-k3s` README under "ArgoCD gotchas". | DS | This document |

## Takeaways

- `ignoreDifferences` is a diff-trigger filter, not a write filter. To prevent
  a resource from being modified by ArgoCD, the only robust option is to keep
  it out of the chart's rendered manifest. `Prune=false` then prevents the
  object from being deleted when it leaves desired state.
- Configuration-loaded-at-startup creates a long, silent gap between
  config-on-disk being broken and the failure being observable. Either reload
  config periodically (and log the version/hash) or fail loudly at startup if
  required fields are missing/empty.
- For single-operator homelabs running GitOps, the operational story for
  secrets needs to be decided up-front: either commit to sealed/encrypted
  secrets in git, or accept that Secrets live outside the GitOps surface and
  design charts accordingly. Mixed models — Secret declared in chart with
  empty values, real values applied manually — are a footgun.
- Age of a Kubernetes object (`AGE` in `kubectl get`, `creationTimestamp` in
  YAML) does not tell you when its `data` was last mutated. Use
  `resourceVersion` or `managedFields[].time` when investigating mutation
  history.
