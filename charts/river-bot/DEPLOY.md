# Deploying river-bot on k3s via ArgoCD

Mirrors the `wc2026bot` setup: image built locally on the node
(`pullPolicy: Never`, no registry), Helm chart lives in `homelab-k3s`,
config/secrets via a manually-created Secret, ArgoCD auto-syncs the chart.

## 0. Stop the systemd version first - important

The bot uses Telegram long-polling. If the systemd service on the Pi and a
new k8s pod are both polling the same `BOT_TOKEN` at once, Telegram will
throw `Conflict: terminated by other getUpdates request`, and for a while
you may get duplicate replies (we saw exactly this earlier with two stray
processes). Stop and disable it before the pod comes up:

```bash
sudo systemctl stop riverbot.service
sudo systemctl disable riverbot.service
```

## 1. Build the image on the node

On the k3s node (same Pi, `homebridge`), in the river-bot repo directory:

```bash
cd /home/bibigon88/river-bot
# copy in Dockerfile and .dockerignore from this delivery first
docker build -t river-bot:latest .
docker images | grep river-bot   # sanity check
```

**Important:** this k3s node runs its own containerd, not the Docker daemon
- `docker build` puts the image in Docker's store, which containerd/kubelet
can't see. With `pullPolicy: Never` you must import it explicitly:

```bash
docker save river-bot:latest | sudo k3s ctr images import -
sudo k3s crictl images | grep river-bot   # confirm it's visible to containerd
```

Do this after every rebuild (see "Updating later" below).

## 2. Create the Secret (not tracked in git)

Namespace `apps`, name `river-bot-env` (must match `<release-name>-env`;
ArgoCD sets the Helm release name to the Application name, i.e. `river-bot`):

```bash
kubectl -n apps create secret generic river-bot-env \
  --from-literal=BOT_TOKEN='<your bot token>' \
  --from-literal=CHAT_ID='<your chat id>' \
  --from-literal=USGS_SITES='11446500,11447650' \
  --from-literal=SCHEDULE_TIME='07:00' \
  --from-literal=TIMEZONE='America/Los_Angeles' \
  --from-literal=SALMON_TEMP_THRESHOLD_F='65' \
  --from-literal=DEFAULT_LANGUAGE='en'
```

## 3. Add the Helm chart to homelab-k3s

```bash
cd /path/to/homelab-k3s
mkdir -p charts/river-bot/templates
# IMPORTANT: Chart.yaml and values.yaml go directly under charts/river-bot/,
# but _helpers.tpl, deployment.yaml and pvc.yaml MUST go under
# charts/river-bot/templates/ - Helm only renders files in templates/.

git add charts/river-bot argocd/river-bot-app.yaml
git commit -m "Add river-bot Helm chart"
git push
```

(Optional sanity check before pushing, if you have Helm installed:
`helm template charts/river-bot` and eyeball the output.)

## 4. Create the ArgoCD Application

```bash
kubectl apply -f argocd/river-bot-app.yaml
```

ArgoCD polls git on an interval; to make it pick up a fresh push immediately:

```bash
kubectl patch application river-bot -n argocd --type merge \
  -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}'
```

## 5. Verify

```bash
kubectl get application river-bot -n argocd
kubectl get pods -n apps | grep river-bot
kubectl logs -n apps -l app.kubernetes.io/name=river-bot -f
```

If the pod shows `ErrImageNeverPull`, the image wasn't imported into
containerd - go back and run the `k3s ctr images import` step above.

In Telegram, send `/now` - should get a response from the pod, not the old
systemd process (which is now stopped).

## Updating later

Push chart changes to `homelab-k3s` - ArgoCD's `selfHeal`/`automated` sync
policy picks them up (use the hard-refresh command above to skip the poll
delay). If you change `bot.py`, you must rebuild **and re-import** the image,
then restart the pod:

```bash
cd /home/bibigon88/river-bot
docker build -t river-bot:latest .
docker save river-bot:latest | sudo k3s ctr images import -
kubectl -n apps rollout restart deployment river-bot
```
