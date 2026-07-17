# Local Image Builds Cause Transient Service Degradation

## Symptom

Multiple unrelated `HomelabServiceDown` / `SLOProbeBurnRateCritical` alerts
fire simultaneously across services that share no obvious dependency
(e.g. influxdb, pihole, homebridge, cadvisor, argocd all at once).
Blackbox HTTP probes report ">2 minutes unreachable", then everything
recovers on its own within a few minutes without any manual fix.

## Cause

`docker build` + `docker save | k3s ctr images import -` on the Pi 5 node
is CPU/I/O heavy. The node runs Prometheus, Grafana, Loki, Tempo, Traefik,
and the whole k3s control plane on the same box, so a build can starve
Traefik's LoadBalancer path (ServiceLB) long enough for blackbox probes
to time out on every `*.homelab.local` HTTPS check at once - even though
no individual service actually crashed.

## How to confirm

```bash
uptime                          # load spike?
free -h                         # memory pressure?
for url in influxdb pihole homebridge cadvisor argocd grafana uptime; do
  code=$(curl -sk -o /dev/null -w "%{http_code}" -m 3 "https://$url.homelab.local")
  echo "$url: $code"
done
```

If services answer normally within a minute or two of the build finishing,
this was the cause - no further action needed, just let the alerts clear.

## Mitigation

Standard practice as of 2026-07-17: wrap every local build/import with
`nice`/`ionice` so it competes less aggressively for CPU and disk I/O:

```bash
nice -n 19 ionice -c3 docker build -t <image>:latest .
nice -n 19 ionice -c3 docker save <image>:latest | sudo ionice -c3 k3s ctr images import -
```

This is now baked into [river-bot's DEPLOY.md](../../charts/river-bot/DEPLOY.md).
Apply the same pattern to any other bot's build/deploy steps.

- Even with `nice`/`ionice`, a brief SLO burn-rate blip is still possible
  under heavy load - this is a mitigation, not a guarantee. This remains a
  known cost of building images locally on a single-node cluster (see
  [ADR-001](../adr/001-k3s.md)).
- For a fully build-free deploy, build on a separate machine and
  `k3s ctr images import` the saved tarball instead of building in place.
- Not worth suspending chaos-monkey for this - it's a self-resolving
  blip, not an actual failure.
