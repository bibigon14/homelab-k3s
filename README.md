# homelab-k3s

Kubernetes manifests for my Raspberry Pi 5 homelab — a single-node [k3s](https://k3s.io/) cluster running everything that used to live on Docker Compose and systemd/cron.

## Why

Started on Docker Compose and systemd (see [wc2026-telegram-bot](https://github.com/bibigon14/wc2026-telegram-bot), [alertmanager-telegram-bridge](https://github.com/bibigon14/alertmanager-telegram-bridge), [iptv-traceroute-analyzer](https://github.com/bibigon14/iptv-traceroute-analyzer)), then migrated everything to k3s as a deliberate step toward more Kubernetes-native patterns — declarative manifests, persistent volumes via `local-path-provisioner`, resource requests/limits, liveness/readiness probes, Secrets instead of `.env` files, and CronJobs instead of host crontab entries.

This repo holds the infrastructure manifests separately from application code — closer to how most teams split app repos from infra/GitOps repos in practice.

## Cluster

- Single-node k3s (`v1.35.5+k3s1`) on a Raspberry Pi 5
- `local-path` is the default StorageClass (k3s built-in)
- Traefik ingress controller (k3s default) — not yet used, reserved for future services that need external access

## Structure

```
namespaces/
  homelab.yaml              # the homelab namespace everything below lives in
apps/
  redis/
    deployment.yaml          # Deployment + PVC + Service for shared Redis cache
  wc2026bot/
    deployment.yaml           # World Cup 2026 Telegram bot (stateless, talks to redis service)
  bridge/
    deployment.yaml            # alertmanager-telegram-bridge (Deployment + NodePort Service)
  iptv/
    cronjobs.yaml               # 3 CronJobs: influx_writer, notify, auto_switch
```

## Apps

### redis
Shared cache + state store used by `wc2026bot` and `notify.py` (IPTV alert dedup). Persists to a 1Gi PVC. Exposed internally as `redis.homelab.svc.cluster.local:6379` (or just `redis:6379` from within the namespace).

### wc2026bot
[World Cup 2026 Telegram bot](https://github.com/bibigon14/wc2026-telegram-bot) — Redis-cached API calls, per-user rate limiting, fully stateless (all state lives in Redis, no PVC needed).

### bridge (alertmanager-telegram-bridge)
[Prometheus Alertmanager → Telegram forwarder](https://github.com/bibigon14/alertmanager-telegram-bridge). Exposed via `NodePort 30119` so the host's systemd-managed Alertmanager can reach it at `http://localhost:30119/webhook`. Config (token, chat ID, routing rules, quiet hours) is mounted from a Secret as `/config/config.yaml`.

### iptv (iptv-traceroute-analyzer)
[IPTV server health monitor](https://github.com/bibigon14/iptv-traceroute-analyzer) — three CronJobs replacing what used to be host crontab entries:
- `iptv-influx-writer` — every 30 min, runs `mtr`-based checks against 8 servers, writes to InfluxDB
- `iptv-notify` — every 30 min, 7am–11pm Pacific only, sends Telegram alerts on server degradation (dedup via Redis)
- `iptv-auto-switch` — hourly, switches active server if needed

All three need `NET_RAW`/`NET_ADMIN` capabilities for `mtr` to work, and an explicit `timeZone: "America/Los_Angeles"` since k8s CronJob schedules default to UTC (the host crontab was implicitly using the system timezone).

Images are built locally with Docker and imported into containerd via `k3s ctr images import` — not pulled from a registry, since this is a single-node homelab cluster, not a multi-node setup that would need one.

Note: InfluxDB and Alertmanager themselves still run on the host (via systemd), not in k3s — the CronJobs reach them via the host's LAN IP, since `localhost` from inside a pod means the pod, not the host.

## Secrets

None of these are in the repo. Create them from each app's existing `.env`/config before applying:

```bash
kubectl create secret generic wc2026-env \
  --from-env-file=/path/to/wc2026-telegram-bot/.env -n homelab

kubectl create secret generic bridge-config \
  --from-file=config.yaml=/path/to/alertmanager-telegram-bridge/config.yaml -n homelab

kubectl create secret generic iptv-env \
  --from-env-file=/path/to/iptv-traceroute-analyzer/.env -n homelab
```

## Deploying

```bash
kubectl apply -f namespaces/homelab.yaml
kubectl apply -f apps/redis/deployment.yaml
# create secrets first (see above), then:
kubectl apply -f apps/wc2026bot/deployment.yaml
kubectl apply -f apps/bridge/deployment.yaml
kubectl apply -f apps/iptv/cronjobs.yaml
```

To update an app after a code change:

```bash
cd /path/to/the-app-repo
docker build -t the-image-name:latest .
docker save the-image-name:latest | sudo k3s ctr images import -
kubectl rollout restart deployment/the-deployment -n homelab
# CronJobs pick up the new image automatically on their next scheduled run
```

## Status

```bash
kubectl get pods -n homelab
kubectl get cronjobs -n homelab
kubectl logs -n homelab deploy/wc2026bot --tail 20
```

## License

MIT
