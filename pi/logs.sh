#!/bin/sh
# Dozzle (visionneuse de logs) et son tunnel sont « à la demande » : profil Compose `logs`, donc absents de `docker compose up -d`.
#   pi/logs.sh on       démarre Dozzle et son tunnel (https://logs.<domaine>, derrière Cloudflare Access)
#   pi/logs.sh off      les arrête (libère ~85 Mo de RAM et ferme l'accès au socket Docker)
#   pi/logs.sh status   état des deux conteneurs
# Un conteneur arrêté à la main reste arrêté après un redémarrage du Pi (restart: unless-stopped).
cd "$(dirname "$0")/.." || exit 1
case "${1:-status}" in
  on)     docker compose --profile logs up -d dozzle cloudflared-logs ;;
  off)    docker compose --profile logs stop dozzle cloudflared-logs ;;
  status) docker compose --profile logs ps -a dozzle cloudflared-logs ;;
  *)      echo "Usage : $0 on | off | status"; exit 1 ;;
esac
