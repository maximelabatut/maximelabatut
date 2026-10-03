#!/bin/sh
# Écrit un statut public minimal (en ligne / hors ligne + uptime), via les URL publiques donc tunnels compris.
chk() {
  code=$(curl -s -o /dev/null -m 8 -w '%{http_code}' "$1")
  [ "$code" = "200" ] && echo true || echo false
}
while true; do
  up=$(cut -d. -f1 /proc/uptime)
  printf '{"updated":%s,"uptime_seconds":%s,"services":{"www":%s,"gamevault":%s,"web2":%s}}\n' \
    "$(date +%s)" "$up" \
    "$(chk https://www.maximelabatut.com/)" \
    "$(chk https://gamevault.maximelabatut.com/)" \
    "$(chk https://web2.maximelabatut.com/)" \
    > /data/status.json.tmp && mv /data/status.json.tmp /data/status.json
  sleep 30
done
