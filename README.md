# homelab-k3s

Kubernetes manifests and Helm charts for my Raspberry Pi 5 homelab — a single-node [k3s](https://k3s.io/) cluster managed via [Helm](https://helm.sh/) and [ArgoCD](https://argo-cd.readthedocs.io/).

## Why

Started on Docker Compose and systemd (see [wc2026-telegram-bot](https://github.com/bibigon14/wc2026-telegram-bot), [alertmanager-telegram-bridge](https://github.com/bibigon14/alertmanager-telegram-bridge), [iptv-traceroute-analyzer](https://github.com/bibigon14/iptv-traceroute-analyzer)), then migrated everything to k3s and progressively added Helm packaging and GitOps-style delivery via ArgoCD — declarative manifests, persistent volumes via `local-path-provisioner`, resource requests/limits, liveness/readiness probes, Secrets instead of `.env` files, and CronJobs instead of host crontab entries.

This repo holds infrastructure manifests and Helm charts separately from application code — closer to how most teams split app repos from infra/GitOps repos in practice.

## Cluster

- Single-node k3s on a Raspberry Pi 5 8GB
- `local-path` is the default StorageClass (k3s built-in)
- Traefik ingress controller (k3s default) — not yet used, reserved for future services

## Structure

\`\`\`
namespaces/
  homelab.yaml                        # homelab namespace
apps/                                 # legacy raw manifests (reference only)
charts/
  alertmanager-telegram-bridge/       # Helm chart: Deployment + NodePort Service + Secret
  redis/                              # Helm chart: Deployment + PVC + ClusterIP Service
  wc2026bot/                          # Helm chart: Deployment + PVC + Secret (initContainer)
  iptv-traceroute-analyzer/           # Helm chart: 3 CronJobs + Secret
argocd/
  bridge-app.yaml                     # ArgoCD Application for bridge
  redis-app.yaml                      # ArgoCD Application for redis
  wc2026bot-app.yaml                  # ArgoCD Application for wc2026bot
  iptv-app.yaml                       # ArgoCD Application for iptv
\`\`\`

## Apps

### redis
Shared cache and state store used by \`wc2026bot\` and \`iptv-notify\` (alert dedup). Persists to a 1Gi PVC via \`local-path\`. Exposed internally as \`redis:6379\` within the \`homelab\` namespace.

### wc2026bot
[World Cup 2026 Telegram bot](https://github.com/bibigon14/wc2026-telegram-bot) — Redis-cached API calls, per-user rate limiting. \`access.log\` persisted to a 64Mi PVC via \`subPath\` mount (initContainer ensures the file exists before the main container starts).

### bridge (alertmanager-telegram-bridge)
[Prometheus Alertmanager → Telegram forwarder](https://github.com/bibigon14/alertmanager-telegram-bridge). Exposed via \`NodePort 30119\` so the host's systemd-managed Alertmanager can reach it at \`http://localhost:30119/webhook\`. Config (token, chat ID, routing rules, quiet hours) is mounted from a Secret as \`/config/config.yaml\`.

### iptv (iptv-traceroute-analyzer)
[IPTV server health monitor](https://github.com/bibigon14/iptv-traceroute-analyzer) — three CronJobs replacing what used to be host crontab entries:
- \`iptv-influx-writer\` — every 30 min, runs \`mtr\`-based checks against 8 servers, writes to InfluxDB
- \`iptv-notify\` — at :15 and :45, 7am–11pm Pacific, sends Telegram alerts on degradation (dedup via Redis)
- \`iptv-auto-switch\` — hourly, switches active IPTV server based on hysteresis logic

All three require \`NET_RAW\`/\`NET_ADMIN\` capabilities for \`mtr\`, and explicit \`timeZone: "America/Los_Angeles"\` since k8s CronJob schedules default to UTC.

Images are built locally with Docker and imported into containerd via \`k3s ctr images import\` — no registry needed on a single-node cluster.

Note: InfluxDB and Alertmanager run on the host via systemd, not in k3s. CronJobs reach them via the host's LAN IP (\`192.168.50.212\`).

## Helm

Each app is packaged as a Helm chart under \`charts/\`. Sensitive values (tokens, API keys) live in \`values.secret.yaml\` which is excluded from the repo via \`.gitignore\`.

### Install / upgrade

\`\`\`bash
cd charts/<chart-name>
helm install <release-name> . -f values.secret.yaml -n homelab
helm upgrade <release-name> . -f values.secret.yaml -n homelab
\`\`\`

### Check releases

\`\`\`bash
helm list -n homelab
\`\`\`

### Create values.secret.yaml

Each chart's \`values.yaml\` contains placeholder empty strings for sensitive fields. Copy and fill in:

\`\`\`bash
# bridge
cat > charts/alertmanager-telegram-bridge/values.secret.yaml << 'EOF'
config:
  telegram:
    token: "<bot-token>"
    default_chat_id: "<chat-id>"
  routes:
    - match:
        severity: critical
      chat_id: "<chat-id>"
      continue: false
    - match:
        severity: warning
      chat_id: "<chat-id>"
      continue: false
EOF

# wc2026bot
cat > charts/wc2026bot/values.secret.yaml << 'EOF'
env:
  BOT_TOKEN: "<token>"
  CHAT_ID: "<chat-id>"
  CHECK_INTERVAL: "5"
  FOOTBALL_API_KEY: "<key>"
  LANG_BOT: "ru"
  SEND_TIME: "08:00"
EOF

# iptv
cat > charts/iptv-traceroute-analyzer/values.secret.yaml << 'EOF'
env:
  CBILLING_USER: "<user>"
  CBILLING_PASS: "<pass>"
  CBILLING_SESSION: "<session>"
  CBILLING_PACKAGE: "<package>"
  INFLUX_URL: "http://192.168.50.212:8086"
  INFLUX_TOKEN: "<token>"
  INFLUX_ORG: "homebridge"
  INFLUX_BUCKET: "iptv_metrics"
  TELEGRAM_TOKEN: "<token>"
  TELEGRAM_CHAT_ID: "<chat-id>"
EOF
\`\`\`

## ArgoCD

ArgoCD watches this repo and automatically syncs all 4 apps on every push to \`main\`.

### UI

Available at: \`https://192.168.50.212:30808\`
Login: \`admin\`
Password: \`kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d\`

### Apply ArgoCD Applications

\`\`\`bash
kubectl apply -f argocd/
\`\`\`

### Check sync status

\`\`\`bash
argocd app list
\`\`\`

### Expose ArgoCD server (NodePort)

\`\`\`bash
kubectl patch svc argocd-server -n argocd \
  -p '{"spec": {"type": "NodePort", "ports": [{"port": 443, "targetPort": 8080, "nodePort": 30808, "name": "https"}]}}'
\`\`\`

## Update workflow

After a code change in an app repo:

\`\`\`bash
cd /path/to/app-repo
docker build -t <image>:latest .
docker save <image>:latest | sudo k3s ctr images import -
kubectl rollout restart deployment/<name> -n homelab
# CronJobs pick up the new image on their next scheduled run
\`\`\`

To change chart configuration (non-secret):

\`\`\`bash
# Edit charts/<chart>/values.yaml
git add charts/<chart>/values.yaml
git commit -m "..."
git push
# ArgoCD applies automatically within ~3 minutes
\`\`\`

## Status

\`\`\`bash
kubectl get pods -n homelab
kubectl get cronjobs -n homelab
helm list -n homelab
argocd app list
\`\`\`

## License

MIT
