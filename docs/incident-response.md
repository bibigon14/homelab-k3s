# Incident Response Playbook

## Severity Levels

| Severity | Definition | Response | Example |
|----------|------------|----------|---------|
| SEV-1 | Platform-wide outage | Immediate | Node down, k3s crashed |
| SEV-2 | Single critical service outage | < 30 min | Pi-hole down, Grafana down |
| SEV-3 | Degraded signal, no outage | < 4 hours | SLO burn rate warning |
| SEV-4 | Cosmetic / low impact | Next session | Dashboard typo |

## Step 1 - Detect

Alerts arrive via Telegram. Check:
- Alertmanager UI: https://alertmanager.homelab.local
- Uptime Kuma: https://uptime.homelab.local

## Step 2 - Triage

    kubectl get pods -A | grep -v Running | grep -v Completed
    kubectl get pods -A --sort-by='.status.containerStatuses[0].restartCount' | tail -10
    kubectl describe node | grep -A5 "Conditions:"
    kubectl get events -A --sort-by='.lastTimestamp' | tail -20

## Step 3 - Diagnose

Pod crashlooping:

    kubectl logs <pod> -n <namespace> --previous
    kubectl describe pod <pod> -n <namespace>

Service has no endpoints:

    kubectl get endpoints -n <namespace>

503 from Traefik:

    kubectl get networkpolicy -A
    kubectl logs -n kube-system -l app.kubernetes.io/name=traefik --tail=30

DNS down: see docs/runbooks/dns-outage.md

## Step 4 - Mitigate

    # Restart service
    kubectl rollout restart deployment/<name> -n <namespace>

    # Rollback
    kubectl rollout undo deployment/<name> -n <namespace>

    # Suspend chaos-monkey
    kubectl patch cronjob chaos-monkey -n apps -p '{"spec":{"suspend":true}}'

Node reboot: see docs/runbooks/stack-restart.md

## Step 5 - Postmortem

For SEV-1 and SEV-2, write a postmortem within 24 hours.

Naming: docs/postmortems/YYYY-MM-DD-short-description.md
Index: docs/postmortems/README.md

Sections: summary, impact, timeline (UTC), root cause, contributing factors, action items, takeaways.

Tone: blameless. The question is "what made this failure mode possible?", not "who did the wrong thing?".

## Known gotchas

- Several unrelated services down at once, self-resolving in a few minutes: check whether a `docker build` / `k3s ctr images import` was running. See docs/runbooks/local-image-builds.md.
- Single `Telegram API getUpdates HTTP 409: Conflict` within a minute of a pod reschedule (Restart Count stays 0, new pod under same ReplicaSet hash) — expected crossover blip between old/new long-polling connections, self-resolves. Don't alert on one-off occurrences, only investigate if recurring.
- sre-analytics OTLP DNS error (alloy.monitoring) recurred after the code fix landed on July 19, because `sre-analytics-env` is an imperative Secret (not in git, not managed by Helm/ArgoCD) that still held the old `OTLP_ENDPOINT`, silently overriding the corrected default in sre_analytics.py. If a code-level default fix doesn't "stick," check `kubectl get secret <name> -o yaml` for an explicit env var overriding it.
