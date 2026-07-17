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

- Expect a burst of SLO burn-rate alerts during/after any `docker build` +
  `k3s ctr images import` on this node. This is currently accepted as a
  known cost of building images locally (see [ADR-001](../adr/001-k3s.md)
  on the single-node tradeoff).
- If it becomes disruptive, consider `nice`/`ionice` on the build command,
  or building on a separate machine and `k3s ctr images import`-ing the
  saved tarball instead of building in place.
- Not worth suspending chaos-monkey for this - it's a self-resolving
  blip, not an actual failure.
