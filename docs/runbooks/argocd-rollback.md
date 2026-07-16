# Runbook: ArgoCD Rollback

Use when a git push broke a deployment.

## Option A - Revert git commit (preferred)

    cd ~/homelab-k3s
    git revert HEAD --no-edit
    git push
    # ArgoCD auto-syncs within ~3 minutes

## Option B - Roll back via ArgoCD UI

1. Open https://argocd.homelab.local
2. Select the broken Application
3. History and Rollback -> pick last known-good revision -> Rollback

Note: rollback disables auto-sync. Re-enable after the fix lands in git.

## Option C - kubectl rollout (fastest)

    kubectl rollout undo deployment/<name> -n <namespace>
    kubectl rollout status deployment/<name> -n <namespace>

## Check sync status

    kubectl get applications -n argocd
