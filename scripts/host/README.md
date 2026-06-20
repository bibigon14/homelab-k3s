# Host-side scripts

Scripts that run directly on the Raspberry Pi host (via cron or systemd
timer), not in Kubernetes. They feed metrics into Prometheus through
the node_exporter textfile collector at /var/lib/prometheus/node-exporter/.

## speedtest-exporter.sh

Runs the official Ookla speedtest CLI and writes a .prom file with
bandwidth, ping, jitter, packet loss, and loaded latency metrics.

Install:
    sudo cp speedtest-exporter.sh /usr/local/bin/
    sudo chmod +x /usr/local/bin/speedtest-exporter.sh

Cron entry (hourly at :55):
    55 * * * * /usr/local/bin/speedtest-exporter.sh >> /home/bibigon88/speedtest.log 2>&1

Dependencies: speedtest (Ookla official CLI from packagecloud), jq.

History: migrated 2026-06-20 from the unmaintained Python
speedtest-cli 2.1.3, which had started returning a sentinel value
of 1800000 ms for ping when it failed to negotiate with a server.
