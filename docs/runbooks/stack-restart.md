# Runbook: Full Stack Restart (after node reboot)

Expected auto-recovery time: 3-5 minutes. k3s and most services restart automatically via systemd.

## 1. Verify node and k3s

    sudo systemctl status k3s
    kubectl get nodes

## 2. Check host systemd services

    for svc in pihole-FTL prometheus grafana alertmanager influxdb homebridge; do
      echo "$svc: $(systemctl is-active $svc)"
    done

Restart any that failed: sudo systemctl restart <service>

## 3. Check pods

    kubectl get pods -A | grep -v Running | grep -v Completed
    kubectl get pods -A --sort-by='.status.containerStatuses[0].restartCount' | tail -10

Common causes after reboot:
- DNS not ready: river-bot/wc2026bot fail with ENOTFOUND. They retry automatically. Wait 30s.
- PVC not mounted: kubectl describe pod <name> to investigate.

## 4. Verify observability

    curl -s http://localhost:9090/api/v1/targets | python3 -m json.tool | grep '"health"' | sort | uniq -c
    curl -s http://localhost:30811/ready
    curl -s http://localhost:9093/-/healthy

## 5. Suspend chaos-monkey during recovery (optional)

    kubectl patch cronjob chaos-monkey -n apps -p '{"spec":{"suspend":true}}'
    # Re-enable when stable:
    kubectl patch cronjob chaos-monkey -n apps -p '{"spec":{"suspend":false}}'
