# Runbook: DNS Outage (*.homelab.local not resolving)

Symptoms: Services unreachable by hostname, getaddrinfo ENOTFOUND in logs, Uptime Kuma shows all hosts down simultaneously.

Severity: SEV-2

## Diagnosis

    systemctl status pihole-FTL
    dig grafana.homelab.local @192.168.50.212
    sudo journalctl -u pihole-FTL -n 50 --no-pager
    sudo journalctl -u pihole-FTL | grep -i "database|lock|sqlite|busy"

## Fix: Pi-hole FTL crash / SQLite deadlock

    sudo systemctl restart pihole-FTL
    sleep 5
    dig grafana.homelab.local @192.168.50.212

If restart doesn't help (database corruption):

    sudo systemctl stop pihole-FTL
    sudo sqlite3 /etc/pihole/pihole-FTL.db "PRAGMA integrity_check;"
    sudo mv /etc/pihole/pihole-FTL.db /etc/pihole/pihole-FTL.db.bak
    sudo systemctl start pihole-FTL

## Fix: CoreDNS not forwarding

    kubectl rollout restart deployment/coredns -n kube-system

## Fix: custom DNS entries missing

    sudo pihole-FTL --config dns.hosts '[
      "192.168.50.1 router.asus.com",
      "192.168.50.212 argocd.homelab.local",
      "192.168.50.212 grafana.homelab.local",
      "192.168.50.212 uptime.homelab.local",
      "192.168.50.212 homebridge.homelab.local",
      "192.168.50.212 influxdb.homelab.local",
      "192.168.50.212 pihole.homelab.local",
      "192.168.50.212 cadvisor.homelab.local",
      "192.168.50.212 thanos.homelab.local",
      "192.168.50.212 alertmanager.homelab.local",
      "192.168.50.212 prometheus.homelab.local"
    ]'
    sudo systemctl restart pihole-FTL

## Verification

    for svc in grafana alertmanager prometheus argocd pihole; do
      echo -n "$svc: "
      dig +short $svc.homelab.local @192.168.50.212
    done

## Known incidents

- 2026-07-11: docs/postmortems/2026-07-11-postmortem-pihole-sqlite-arp-deadlock.md
