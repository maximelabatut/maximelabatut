#!/bin/sh
# Écrit un statut public minimal (en ligne / hors ligne + uptime). www et web2 sont testés via leur URL publique (tunnel compris);
# GameVault est derrière Cloudflare Access (une URL publique répondrait par la page de connexion) : on teste l'application
# elle-même, par son nom sur le réseau Docker.
chk() {
  code=$(curl -s -o /dev/null -m 8 -w '%{http_code}' "$1")
  [ "$code" = "200" ] && echo true || echo false
}
while true; do
  up=$(cut -d. -f1 /proc/uptime)
  printf '{"updated":%s,"uptime_seconds":%s,"services":{"www":%s,"gamevault":%s,"web2":%s}}\n' \
    "$(date +%s)" "$up" \
    "$(chk https://www.maximelabatut.com/)" \
    "$(chk http://gamevault:8787/)" \
    "$(chk https://web2.maximelabatut.com/)" \
    > /data/status.json.tmp && mv /data/status.json.tmp /data/status.json
  sleep 60   # un test toutes les 60 s (30 s avant) : le statut public reste frais (la page l'estime périmé au-delà de 3 min)
done
