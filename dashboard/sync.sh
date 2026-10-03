#!/bin/sh
# Écrit la liste des conteneurs (id court, nom, image) pour le dashboard. Jamais la commande ni l'environnement.
while true; do
  docker ps -a --format '{"id":"{{.ID}}","name":"{{.Names}}","image":"{{.Image}}"}' \
    | paste -sd, | sed 's/^/[/; s/$/]/' > /data/containers.json.tmp \
    && mv /data/containers.json.tmp /data/containers.json
  sleep 10
done
