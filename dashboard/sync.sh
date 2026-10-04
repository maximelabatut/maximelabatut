#!/bin/sh
# Écrit la liste des conteneurs (id court, nom, image) pour le dashboard. Jamais la commande ni l'environnement.
# Rafraîchissement piloté par les événements Docker (création, démarrage, arrêt, destruction, renommage) au lieu d'un
# `docker ps -a` toutes les 10 s. Sans événement, la liste est réécrite toutes les REFRESH_MAX secondes (sécurité).
# Si le flux d'événements se termine aussitôt (format refusé, démon indisponible), on patiente 30 s avant de réessayer
# au lieu de boucler à plein régime. Sous busybox, `read -t` renvoie le même code (1) pour un délai dépassé et pour une fin de
# flux : on les distingue par le temps écoulé.
REFRESH_MAX="${REFRESH_MAX:-300}"
refresh() {
  docker ps -a --format '{"id":"{{.ID}}","name":"{{.Names}}","image":"{{.Image}}"}' \
    | paste -sd, | sed 's/^/[/; s/$/]/' > /data/containers.json.tmp \
    && mv /data/containers.json.tmp /data/containers.json
}
while true; do
  refresh
  started=$(date +%s)
  docker events --filter type=container --filter event=create --filter event=start --filter event=die \
    --filter event=destroy --filter event=rename --format '{{.Action}}' |
  while true; do
    waited=$(date +%s)
    if read -r -t "$REFRESH_MAX" _; then
      refresh; sleep 1
    elif [ $(( $(date +%s) - waited )) -ge $(( REFRESH_MAX - 2 )) ]; then
      refresh                      # délai dépassé sans événement : on rafraîchit et on continue d'écouter
    else
      break                        # fin du flux
    fi
  done
  [ $(( $(date +%s) - started )) -lt 5 ] && sleep 30
  sleep 2
done
