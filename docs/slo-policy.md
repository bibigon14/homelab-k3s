# SLO Policy

## Philosophy

SLOs here mirror production SRE practice: each service has a defined availability target, an error budget derived from that target, and burn rate alerts that fire before the budget is exhausted.

## Services and Targets

| Service | Target | Window | Probe |
|---------|--------|--------|-------|
| Pi-hole | 99.9% | 7 days | Blackbox HTTP |
| Prometheus | 99.9% | 7 days | Blackbox HTTP |
| Grafana | 99.9% | 7 days | Blackbox HTTP |
| Alertmanager | 99.9% | 7 days | Blackbox HTTP |
| ArgoCD | 99.9% | 7 days | Blackbox HTTP |
| Homebridge | 99.9% | 7 days | Blackbox HTTP |
| wc2026bot | 99.9% | 7 days | Blackbox HTTP |
| bridge | 99.9% | 7 days | Blackbox HTTP |
| Thanos Query | 99.9% | 7 days | Blackbox HTTP |
| node (Pi) | 99.9% | 7 days | Blackbox ICMP |

## Error Budget

For a 7-day window with 99.9% target:

    Error budget = (1 - 0.999) x 7 x 24 x 60 = 10.08 minutes per week

## Burn Rate Alerts

| Alert | Burn Rate | Windows | Meaning |
|-------|-----------|---------|---------|
| SLOServiceBurnRateCritical | 14x | 1h + 5m | Budget exhausted in ~12h. Act now. |
| SLOServiceBurnRateWarning | 6x | 6h + 30m | Budget exhausted in ~28h. Investigate today. |

## Budget Spend Policy

| Budget Remaining | Action |
|------------------|--------|
| > 50% | Normal. Chaos monkey runs. |
| 25-50% | Investigate open incidents. Consider suspending chaos monkey. |
| 10-25% | Suspend chaos monkey. No planned maintenance. |
| < 10% | Freeze all changes. Reliability only. |

## Chaos Engineering and SLOs

chaos-monkey kills a random pod hourly - this is intentional budget spend. Services should recover within 2-3 minutes. Longer recovery indicates a resilience gap.

Known gap: single-replica deployments (wc2026bot, bridge) lose ~2 min per kill. Fix: replicas + webhook mode (planned).

## Dashboards

- Grafana: https://grafana.homelab.local -> Raspberry Pi 5 -> SLO Error Budgets
- Uptime Kuma: https://uptime.homelab.local
