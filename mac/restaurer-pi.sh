#!/bin/bash
# À lancer depuis le Mac, une fois la carte SD flashée (Raspberry Pi Imager) et le Pi démarré sur le WiFi.
# Envoie le .env et lance restore.sh sur le Pi. Un seul mot de passe SSH à saisir, plus le futur mot de passe Samba.
set -euo pipefail

HOST="maxime@maxime.local"
ENV_FILE="${ENV_FILE:-$HOME/Desktop/raspberrypi/.env}"
RAW="https://raw.githubusercontent.com/maximelabatut/maximelabatut/main/restore.sh"
LOCAL_RESTORE="$HOME/Desktop/raspberrypi/restore.sh"

[ -f "$ENV_FILE" ] || { echo "Fichier introuvable : $ENV_FILE"; exit 1; }

TMP="$(mktemp -d /tmp/pirestore.XXXXXX)"
SOCK="$TMP/ssh.sock"
trap 'ssh -O exit -o ControlPath="$SOCK" "$HOST" >/dev/null 2>&1 || true; rm -rf "$TMP"' EXIT

if curl -fsSL "$RAW" -o "$TMP/restore.sh"; then
  echo "restore.sh récupéré depuis GitHub."
elif [ -f "$LOCAL_RESTORE" ]; then
  cp "$LOCAL_RESTORE" "$TMP/restore.sh"
  echo "GitHub injoignable : copie locale de restore.sh utilisée."
else
  echo "restore.sh introuvable (ni sur GitHub, ni dans $LOCAL_RESTORE)."; exit 1
fi

# La clé SSH du Pi change à chaque reflash.
ssh-keygen -R maxime.local >/dev/null 2>&1 || true

OPTS=(-o StrictHostKeyChecking=accept-new -o ControlMaster=auto -o ControlPath="$SOCK" -o ControlPersist=30m)

echo "Connexion au Pi (saisis le mot de passe de l'utilisateur maxime, une seule fois)..."
ssh "${OPTS[@]}" "$HOST" true

scp "${OPTS[@]}" "$ENV_FILE" "$HOST:/tmp/pi.env"
KUMA_ARCHIVE="${KUMA_ARCHIVE:-$HOME/Desktop/raspberrypi/uptime-kuma-data.tgz}"
if [ -f "$KUMA_ARCHIVE" ]; then
  scp "${OPTS[@]}" "$KUMA_ARCHIVE" "$HOST:/tmp/uptime-kuma-data.tgz"
  echo "Données Uptime Kuma envoyées (sondes, notification ntfy, compte)."
else
  echo "Pas de sauvegarde Uptime Kuma ($KUMA_ARCHIVE) : à reconfigurer à la main."
fi
GV_DIR="${GV_DIR:-$HOME/Desktop/raspberrypi/GameVault}"
GV_DATA="${GV_DATA:-$HOME/Desktop/raspberrypi/gamevault-data.tgz}"
if [ -f "$GV_DIR/rss_proxy_server.py" ] && [ -f "$GV_DIR/GameVault.html" ]; then
  tar czf "$TMP/gamevault-app.tgz" -C "$GV_DIR" GameVault.html rss_proxy_server.py logo.png logo.ico
  scp "${OPTS[@]}" "$TMP/gamevault-app.tgz" "$HOST:/tmp/gamevault-app.tgz"
  echo "Code GameVault envoyé (depuis $GV_DIR)."
else
  echo "Code GameVault introuvable dans $GV_DIR : GameVault ne démarrera pas tant que ~/docker/gamevault/app est vide."
fi
if [ -f "$GV_DATA" ]; then
  scp "${OPTS[@]}" "$GV_DATA" "$HOST:/tmp/gamevault-data.tgz"
  echo "Base GameVault envoyée (catalogue de jeux, wishlist)."
else
  echo "Pas de sauvegarde de la base GameVault ($GV_DATA) : GameVault repartira avec une base vide."
fi
scp "${OPTS[@]}" "$TMP/restore.sh" "$HOST:/tmp/restore.sh"
ssh -t "${OPTS[@]}" "$HOST" "bash /tmp/restore.sh; rm -f /tmp/restore.sh"

echo
echo "Le Pi redémarre. Dans ~2 minutes : https://www.maximelabatut.com et https://config.maximelabatut.com"
