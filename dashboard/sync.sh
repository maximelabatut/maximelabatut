#!/bin/sh
# Écrit la liste des conteneurs (id court, nom, image) pour le dashboard. Jamais la commande ni l'environnement.
# Rafraîchissement piloté par les événements Docker (création, démarrage, arrêt, destruction, renommage) au lieu d'un
# `docker ps -a` toutes les 10 s : quasi aucune charge pour le démon. Si aucun événement n'arrive pendant REFRESH_MAX secondes
# (ou si le flux se coupe, par exemple au redémarrage du démon Docker), la liste est réécrite et le flux est rouvert.
# Note : sous busybox, `read -t` renvoie le même code (1) pour un délai dépassé et pour une fin de flux.
REFRESH_MAX="${REFRESH_MAX:-300}"
refresh() {
  docker ps -a --format '{"id":"{{.ID}}","name":"{{.Names}}","image":"{{.Image}}"}' \
    | paste -sd, | sed 's/^/[/; s/$/]/' > /data/containers.json.tmp \
    && mv /data/containers.json.tmp /data/containers.json
}
while true; do
  refresh
  docker events --filter type=container --filter event=create --filter event=start --filter event=die \
    --filter event=destroy --filter event=rename --format '{{.ID}}' 2>/dev/null |
  while read -r -t "$REFRESH_MAX" _; do
    refresh; sleep 1
  done
  sleep 2
done
