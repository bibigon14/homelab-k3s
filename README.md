# homelab-k3s

Kubernetes manifests for my Raspberry Pi 5 homelab — a single-node [k3s](https://k3s.io/) cluster running migrated workloads from a previous Docker Compose setup.

## Why

Started on Docker Compose (see [wc2026-telegram-bot](https://github.com/bibigon14/wc2026-telegram-bot)), then migrated to k3s as a deliberate step toward more Kubernetes-native patterns — declarative manifests, persistent volumes via `local-path-provisioner`, resource requests/limits, liveness/readiness probes, and Secrets instead of `.env` files baked into Compose.

This repo holds the infrastructure manifests separately from application code — closer to how most teams split app repos from infra/GitOps repos in practice.

## Cluster

- Single-node k3s (`v1.35.5+k3s1`) on a Raspberry Pi 5
- `local-path` is the default StorageClass (k3s built-in)
- Traefik ingress controller (k3s default) — not yet used, reserved for future services that need external access

## Structure

```
namespaces/
  homelab.yaml          # the homelab namespace everything below lives in
apps/
  redis/
    deployment.yaml      # Deployment + PVC + Service for shared Redis cache
  wc2026bot/
    deployment.yaml       # World Cup 2026 Telegram bot (stateless, talks to redis service)
```

## Apps

### redis
Shared cache + state store used by `wc2026bot` (and future workloads). Persists to a 1Gi PVC. Exposed internally as `redis.homelab.svc.cluster.local:6379` (or just `redis:6379` from within the namespace).

### wc2026bot
[World Cup 2026 Telegram bot](https://github.com/bibigon14/wc2026-telegram-bot) — Redis-cached API calls, per-user rate limiting, fully stateless (all state lives in Redis, no PVC needed). Image is built locally with Docker and imported into containerd via `k3s ctr images import` — not pulled from a registry, since this is a single-node homelab cluster, not a multi-node setup that would need one.

Requires a `wc2026-env` Secret with the bot's environment variables (`BOT_TOKEN`, `CHAT_ID`, `FOOTBALL_API_KEY`, etc.) — **not included in this repo**. Create it from the bot's existing `.env` file:

```bash
kubectl create secret generic wc2026-env \
  --from-env-file=/path/to/wc2026-telegram-bot/.env \
  -n homelab
```

## Deploying

```bash
kubectl apply -f namespaces/homelab.yaml
kubectl apply -f apps/redis/deployment.yaml
# create the wc2026-env secret first (see above), then:
kubectl apply -f apps/wc2026bot/deployment.yaml
```

To update the bot after a code change:

```bash
cd /path/to/wc2026-telegram-bot
docker build -t wc2026-telegram-bot-wc2026bot:latest .
docker save wc2026-telegram-bot-wc2026bot:latest | sudo k3s ctr images import -
kubectl rollout restart deployment/wc2026bot -n homelab
```

## Status

```bash
kubectl get pods -n homelab
kubectl logs -n homelab deploy/wc2026bot --tail 20
```

## What's not here yet

- `endpoint-health-monitor` (IPTV monitor) — still running via cron + systemd on the host
- `alertmanager-telegram-bridge` — still running via systemd on the host (doesn't depend on Redis, no pressing need to containerize/migrate)
- Ingress / external access — not needed yet, everything talks to Telegram outbound

## License

MIT
