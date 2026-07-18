# Postmortems

Blameless postmortems for incidents and notable bugs on the homelab kubernetes
platform. Each follows a shared template: summary, impact, timeline in UTC,
root cause, contributing factors, what helped / what did not, action items,
takeaways.

Intended audience: future self (so the same mistakes are not made twice) and
anyone interested in the operational history of this platform.

## Index

| Date | Title | Severity |
|---|---|---|
| 2026-07-18 | [Pi-hole loopback drop + Thanos compact crash loop (three root causes in one alert)](./2026-07-18-postmortem-pihole-loopback-drop-thanos-cascade.md) | SEV-3 |
| 2026-07-11 | [Pi-hole SQLite ARP deadlock caused homelab-wide DNS outage](./2026-07-11-postmortem-pihole-sqlite-arp-deadlock.md) | SEV-2 |
| 2026-06-20 | [Quiet-hours suppression dropped resolved-alert notifications](./2026-06-20-quiet-hours-suppressed-resolved-alerts.md) | SEV-3 |
| 2026-06-20 | [Telegram alert delivery silently broken by ArgoCD overwriting Secret data](./2026-06-20-argocd-secret-data-overwrite.md) | SEV-2 |
| 2026-06-20 | [Code fixes silently not deployed for ~14 hours due to docker build / containerd image-store mismatch](./2026-06-20-docker-vs-containerd-image-store.md) | SEV-2 |

## Format

- **Severity:** SEV-1 (platform-wide outage) / SEV-2 (single critical service
  outage or silent data loss) / SEV-3 (degraded signal quality, no service
  outage) / SEV-4 (cosmetic).
- **Timeline:** all timestamps in UTC unless otherwise noted, regardless of
  local timezone of the host or operator.
- **Action items:** each row has an owner and a status (Done / Todo /
  Decided-not-to-do, with rationale).
- **Tone:** blameless. The questions are "what made the failure mode possible?"
  and "what change to the system or process prevents recurrence?", never "who
  did the wrong thing?".
