# Postmortem: iptv-auto-switch false-positive session-expired alerts caused by a bare `except` that treated transient network failures as cookie expiry

**Date:** 2026-08-29
**Author:** DS
**Status:** Resolved
**Severity:** SEV-3 (alert-quality degradation; monitored function unaffected)
**Services affected:** `iptv-auto-switch` CronJob (`apps` namespace)
**Platform:** homelab kubernetes platform (k3s, single node, ArgoCD + Helm, ExternalSecrets Operator)

---

## Summary

The `iptv-auto-switch` CronJob (hourly, PDT) sent a Telegram alert at 2026-08-29 08:00 PDT claiming the cbilling.eu session cookie had expired, with instructions to rotate `PHPSESSID` in `~/.env` on the Pi. The cookie had not in fact expired: three Pods were created for the 08:00 Job (initial run + two `backoffLimit` retries), and the third succeeded within 82 seconds of the second's failure with no configuration change of any kind. The alert had already been sent from the second Pod's failure, so it fired on what turned out to be a self-healed transient.

The alert body was also architecturally wrong. It instructed rotating `~/.env` on the Pi, but the CronJob does not read from that file - it reads from Secret `iptv-env` in namespace `apps`, which is managed by ExternalSecrets Operator against ClusterSecretStore `kubernetes-secrets` (key `iptv-secrets`, refresh 1h). Any edit to `~/.env`, or even a direct `kubectl patch` on the Secret, is reverted by ESO on next sync. The alert text was written before the secret was migrated to ESO and had drifted from reality.

Root cause was three antipatterns compounded in a single 8-line function:

```python
def check_session() -> bool:
    try:
        session = requests.Session()
        session.headers.update({'User-Agent': 'Mozilla/5.0'})
        session.cookies.set('PHPSESSID', CBILLING_SESSION, domain='cbilling.eu')
        resp = session.get(f'https://cbilling.eu/?mode=iptv_settings2&package={CBILLING_PACKAGE}', timeout=10)
        return 'Пополнить' in resp.text and 'iserver' in resp.text
    except:
        return False
```

1. `except:` catches every exception including `Timeout`, `ConnectionError`, `KeyboardInterrupt` and `MemoryError`, and collapses them all into the single signal "session expired." A DNS glitch, an upstream 500, or a TLS renegotiation failure was indistinguishable from a genuinely dead cookie.
2. The success check is HTML string-matching against two Russian-language markers in the response body. Any layout change on cbilling.eu produces a false negative.
3. There is no retry. A single failed HTTP request wins immediately, then `backoffLimit: 2` on the Job produces up to three separate alert-eligible attempts, each of which independently sends a Telegram message if it hits.

The Job's exit-code contract compounded the problem: `sys.exit(1)` on transient failure counted the Job as failed, contributed to `BackoffLimitExceeded`, and produced alert noise for a class of event that should have been handled silently and retried on the next scheduled invocation.

The stale-alert-text half of this incident is a variant of the pattern documented in [2026-06-20-argocd-secret-data-overwrite.md](./2026-06-20-argocd-secret-data-overwrite.md) and [2026-07-24-postmortem-sre-analytics-otlp-drift.md](./2026-07-24-postmortem-sre-analytics-otlp-drift.md): an f-string containing operator instructions is code that ages against the architecture it describes, and no test or review step in this platform currently catches that kind of drift.

## Impact

- One false-positive Telegram alert delivered at 2026-08-29 08:00 PDT, followed by ~15 minutes of operator time spent applying the alert's own (obsolete) remediation before realizing it was a no-op.
- The 08:00 CronJob run was ultimately successful (third Pod completed cleanly at 08:02 without action), so the monitored function - hourly analysis of 8 IPTV servers via mtr and switching if the leader margin exceeded a hysteresis threshold of 15 - was not affected.
- No customer/user impact. IPTV service remained on server `s03` throughout and switched to `s02` at 08:26 during the verification run of the fix.
- This is the fourth `iptv-auto-switch` false-positive of the same shape observed in the last ~90 days; prior occurrences were dismissed as "transient network" without a code-level fix. Historical alert log confirms the pattern.

## Timeline (all times PDT, 2026-08-29)

| Time | Event |
|---|---|
| 08:00:xx | Pod `iptv-auto-switch-29800260-q8w54` fails on `check_session()`. |
| 08:00:xx | Pod `iptv-auto-switch-29800260-nqbv5` fails on `check_session()`. Telegram alert sent from this Pod. |
| 08:01:xx | Pod `iptv-auto-switch-29800260-2cv9c` (third attempt within Job's `backoffLimit`) succeeds. Log: `✅ Сессия активна! ... 🏆 Лучший сервер: s01 (95) ... ℹ️ s01 (95) лучше s03 (85) всего на 10 ≤ 15 - остаёмся на s03`. No configuration change had occurred between the second Pod's failure and the third's success. |
| 08:05 | Operator rotates `PHPSESSID` in `~/.env` on the Pi per alert instructions. |
| 08:07 | `kubectl get cronjob iptv-auto-switch -o yaml` shows `envFrom: - secretRef: name: iptv-env`. The Pi's `~/.env` is not the source of truth. Alert instructions are obsolete. |
| 08:11 | `k get secret iptv-env -n apps -o jsonpath='{.data.PHPSESSID}'` returns empty. The Secret uses key `CBILLING_SESSION`, not `PHPSESSID`. Alert instructions were wrong on the key name too. |
| 08:12 | `grep -nE 'PHPSESSID\|CBILLING' auto_switch.py` locates the bare-except check function and the alert body. |
| 08:15 | `CBILLING_USER` and `CBILLING_PASS` observed in Secret but unreferenced anywhere in the source tree - archaeology of a removed auto-relogin path. Filed as v2 direction. |
| 08:18 | `auto_switch.py` patched: `check_session()` returns a `SessionState` enum (`OK` / `EXPIRED` / `TRANSIENT`), with 3-attempt exponential backoff on `Timeout`/`ConnectionError`/5xx, explicit status-code handling (`301`/`302`/`401`/`403` → EXPIRED), and `allow_redirects=False` so login-redirects are classified rather than followed. Main branches three ways: EXPIRED → alert + `exit 1`, TRANSIENT → log only + `exit 0`, OK → proceed. Alert body corrected to reference `kubectl edit secret iptv-env -n apps`. Commit `8104bdb`. |
| 08:26 | Verification Job runs full happy-path end-to-end: cookie check OK → analyze → switch from `s03` to `s02` (best score 95 vs current 70, delta 25 > hysteresis 15). |
| 08:33 | Second verification Job confirms idempotency (already on `s02`, no action). |
| 08:47 | Live-logging Job hangs silently for 4+ minutes with zero output before dumping everything on completion. Diagnosed as Python stdout buffering (`stdout.isatty() == False` under kubelet). `Dockerfile` amended: `ENV PYTHONUNBUFFERED=1`. Commit `359ff3a`. |
| 08:51 | Attempt to verify EXPIRED path by `kubectl patch`ing Secret with a deliberately invalid cookie. Job runs and reports session as valid. `kubectl get secret ...` shows the real cookie value, not the patched one. |
| 08:55 | `kubectl get secret iptv-env -o yaml` reveals `argocd.argoproj.io/tracking-id: iptv:external-secrets.io/ExternalSecret:apps/iptv-env`. Secret is managed by ExternalSecrets Operator. Any `kubectl patch/edit` is reverted on next ESO sync. |
| 08:57 | EXPIRED path verified out-of-cluster via a local one-liner (`CBILLING_SESSION=invalid python3 -c 'from auto_switch import check_session; print(check_session().value)'`). Output: `[INFO] check_session: HTTP 302 redirect, cookie expired` → `result: expired`. |
| 08:58 | Stale `iptv-bot-deployment.yaml` (namespace `homelab`, which does not exist in this cluster; actual deploy is via Helm chart in `apps`) removed from repo. Commit `258162b`. |

## Root cause

**A `bare except: return False` in `check_session()` collapsed every possible failure mode of an HTTP request - network, upstream, protocol, resource - into the single signal "cookie expired," and the surrounding Job/CronJob exit-code contract turned that signal into an alertable, retry-inducing "failure."** The check had no way to distinguish "cbilling returned a 302 to `/login` because the cookie is dead" from "the DNS query for `cbilling.eu` timed out for 10 seconds because CoreDNS glitched," and it treated the latter with the escalation appropriate to the former.

The `backoffLimit: 2` on the Job meant a single transient blip produced up to three separate attempts to send the alert - each one seeing its own independent transient outcome, so a two-out-of-three failure pattern (as observed at 08:00) produced one alert and one clean success, which visually reads as a real oscillating problem rather than the noise it actually was.

## Contributing factors

1. **`except:` with no exception type.** Catches everything including `KeyboardInterrupt` and `MemoryError`. Standard Python antipattern; the fix is `except (requests.Timeout, requests.ConnectionError) as e:` and let anything else propagate.
2. **HTML string-matching as the success signal.** `'Пополнить' in resp.text and 'iserver' in resp.text` is coupled to cbilling.eu's Russian-language template. A layout tweak upstream produces false negatives with no observable connection to the change; a login page that happens to include either string produces false positives.
3. **`sys.exit(1)` on both real failure and transient failure.** Job/CronJob semantics treat non-zero exit as failure, count it toward `backoffLimit`, and eventually mark the Job `BackoffLimitExceeded`. Conflating "human, act now" with "system, retry" at the process-exit level makes transient blips indistinguishable from real outages in cluster state.
4. **Alert body had drifted from architecture.** The Secret was migrated to ESO after the alert message was written; the message still instructs editing `~/.env` on the Pi. Nothing in the deploy pipeline or code review would catch that kind of documentation drift because the message is a Python f-string, not a doc file.
5. **`imagePullPolicy: Never`.** Correct for a local-image workflow, but combined with kubelet's image cache means a fresh `docker save | k3s ctr images import` does not automatically translate to Pods picking up the new bytes - kubelet retains the last-resolved digest for a given tag until it's restarted or the tag is explicitly retagged. Rollout verification required `sudo systemctl restart k3s` before Pods reliably used the new image.
6. **Python stdout buffering under kubelet.** Without `PYTHONUNBUFFERED=1`, `print()` output accumulated until Pod exit rather than streaming. This hid the fact that verification Jobs were making progress and made every "is it hung?" check require exec into the Pod.
7. **No self-monitoring for alert quality.** Prior transient-flap incidents in the last 90 days were noticed by the operator but not converted into a metric or an alert-on-alert-rate signal that would have surfaced the pattern before the fourth occurrence.

## What helped

- **Reading `kubectl get pod` at Pod granularity, not `kubectl get job`.** The Job-level view showed a single failed Job. The Pod-level view showed three Pods, two `Error` and one `Completed`, all within 82 seconds and all sharing an identical config - the smoking gun for "this is transient, not real."
- **`kubectl exec ... grep -c 'SessionState' /app/auto_switch.py`** against the running container to verify the deployed code matched the committed code. Distinguished "fix isn't working" from "fix isn't deployed" in one command; the answer was `0` for two rebuilds before k3s restart, `11` after.
- **Testing the EXPIRED path with a local Python one-liner** (`CBILLING_SESSION=invalid python3 -c 'from auto_switch import check_session; print(check_session().value)'`) after in-cluster testing was blocked by ESO reverting the Secret. Removed all layers - kubelet, ESO, containerd - and exercised the code against real cbilling.eu directly. Sub-second, no cluster movement, no cleanup risk.
- **`PYTHONUNBUFFERED=1` + `PYTHONDONTWRITEBYTECODE=1` in the Dockerfile.** Two ENV lines; changes `kubectl logs -f` on Python CronJobs from "wait 3 minutes and hope" to actual streaming.

## What did not help

- **Editing `~/.env` on the Pi.** The Pod does not read that file; the effective config is the Secret, managed by ESO. 15 minutes of muscle-memory response before checking the actual source of truth.
- **`kubectl patch secret iptv-env` to inject a test value.** Silently reverted by ESO within the refresh interval (up to 1h). Any test that relies on modifying a Secret managed by an external controller must first suspend the controller for that resource or bypass it entirely.
- **`docker save iptv-traceroute-analyzer:latest | sudo k3s ctr images import -` alone.** The image ended up in containerd's `k8s.io` namespace with the correct digest, but new Pods still ran the old code because kubelet's image cache retained the pre-import digest for tag `iptv-traceroute-analyzer:latest` under `imagePullPolicy: Never`. `sudo systemctl restart k3s` was required to reset the cache. Retagging with `k3s ctr images tag` may achieve the same effect without a restart; not verified.
- **`kubectl logs -f` on a long-running Job without `PYTHONUNBUFFERED=1`.** Streamed nothing for the full run, then dumped everything at Pod exit. Repeatedly misdiagnosed as "the Job is hung" when it was in fact working normally.

## Action items

| # | Action | Owner | Status |
|---|---|---|---|
| 1 | Ship `check_session` v2 with auto-relogin: on EXPIRED, POST to cbilling.eu login endpoint with `CBILLING_USER`/`CBILLING_PASS` (already in Secret, currently unread), cache new PHPSESSID in Redis (already wired), retry once. Only alert the operator if login itself fails. Eliminates the whole class of "rotate cookie by hand" alerts. | DS | Todo |
| 2 | Add Prometheus counter `iptv_cbilling_check_total{result="ok\|expired\|transient\|error"}` via pushgateway on each run. Grafana alert on `rate(...{result="transient"}[1h]) > 0.1` catches flap patterns before they reach the operator; alert on any single `result="expired"` remains as today. | DS | Todo |
| 3 | Extend `PYTHONUNBUFFERED=1` + `PYTHONDONTWRITEBYTECODE=1` to a chart-level default for all Python-based CronJobs in the homelab platform. Add to the shared `_env.tpl` partial in the Helm chart. | DS | Todo |
| 4 | Document the ExternalSecret-managed Secret pattern (specifically: `kubectl patch/edit` is ephemeral, tests must bypass) in `docs/incident-response.md` under "Known gotchas." | DS | Todo |
| 5 | Audit remaining Python CronJobs in `apps` for the same `bare except → sys.exit(1)` pattern (`iptv-influx-writer`, `iptv-notify`, `sre-analytics`, `chaos-monkey`). Grep for `except:\s*$` and `except Exception:\s*\n.*sys.exit`. | DS | Todo |

## Takeaways

- **The alert message is code.** Every string sent to the operator ages against the architecture it describes, and unlike code paths, alert messages have no test that catches drift. When migrating a Secret to ESO, or a config file to a ConfigMap, grep the codebase for the literal path/filename and update the alert bodies in the same commit.
- **Bare `except:` is worse than no error handling in an alerting path.** No error handling produces a stack trace, which is legible as an unexpected condition. Bare `except: return False` produces a legible-looking normal control-flow result that misclassifies the failure and alerts on it as if it were something else entirely. In an alerting function specifically, the exception type must be narrow enough that anything unexpected propagates and produces a distinguishable failure signal, not a silently-mistyped success.
- **Job/CronJob exit codes are a contract, not an implementation detail.** `exit 1` means "count this against `backoffLimit`, mark the Job failed if the limit is exceeded, and surface that state to the CronJob controller." A transient network failure that should be silently retried on the next schedule must exit 0 with a log line, or the retry mechanism becomes an alert-amplification mechanism.
- **Legacy code artifacts are archaeology worth reading.** `CBILLING_USER`/`CBILLING_PASS` sitting in the Secret with no reader identified the shape of the correct v2 fix (auto-relogin) in the same investigation as the v1 fix (retry + state). Unused config keys are commit-log evidence in the present tense.
