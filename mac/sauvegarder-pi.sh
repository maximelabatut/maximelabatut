#!/bin/bash
# Sauvegarde du Pi vers le Mac : le .env et des instantanés cohérents des bases (Uptime Kuma, GameVault).
#   Manuel :    ~/Backups/raspberrypi/sauvegarder-pi.sh
#   Planifié :  sauvegarder-pi.sh --auto   (sans terminal : journal ~/Library/Logs/homelab-backup.log + notification macOS)
#               Lancé chaque heure par launchd et à l'ouverture de session ; ne fait quelque chose que si la dernière
#               sauvegarde réussie a plus de MAX_AGE_H heures (le Mac n'est pas allumé en permanence).
#
# Fichiers produits dans ~/Backups/raspberrypi (droits 600) :
#   .env                      tokens Cloudflare (+ DOCKER_GID, recalculé à la restauration)
#   uptime-kuma-data.tgz      base SQLite cohérente + db-config.json
#   gamevault-data.tgz        base SQLite de GameVault (catalog.db)
#   *.sh                      copies des scripts de restauration/sauvegarde, prises sur le Pi (toujours à jour)
#   .derniere-sauvegarde      date de la dernière sauvegarde réussie (sert à décider si une nouvelle est nécessaire)
# Historique : les 14 versions précédentes des archives sont gardées dans historique/ ; .env.prev garde l'ancien .env.
#
# Sans mot de passe : le Pi exécute /usr/local/sbin/homelab-backup (root) via une règle sudo NOPASSWD limitée à ce script
# (installée par : sudo bash ~/docker/pi/install-backup.sh). Sans elle, repli interactif (mot de passe sudo demandé).
set -euo pipefail

HOST="maxime@maxime.local"
DEST="${DEST:-$HOME/Backups/raspberrypi}"
AUTO=0; [ "${1:-}" = "--auto" ] && AUTO=1
LOG="$HOME/Library/Logs/homelab-backup.log"
KEEP=14
MAX_AGE_H="${MAX_AGE_H:-20}"      # une sauvegarde automatique est refaite si la dernière réussie date de plus de ...
ALERT_AGE_H="${ALERT_AGE_H:-48}"  # notification si le Pi est injoignable alors que la dernière sauvegarde date de plus de ...
STAMP="$DEST/.derniere-sauvegarde"

age_hours() { [ -f "$STAMP" ] && echo $(( ( $(date +%s) - $(stat -f %m "$STAMP") ) / 3600 )) || echo 9999; }

# Mode planifié : silencieux et immédiat si une sauvegarde récente existe.
if [ "$AUTO" = 1 ] && [ "$(age_hours)" -lt "$MAX_AGE_H" ]; then exit 0; fi

notify() { osascript -e "display notification \"$2\" with title \"Sauvegarde du Pi\" subtitle \"$1\"" >/dev/null 2>&1 || true; }

if [ "$AUTO" = 1 ]; then
  mkdir -p "$(dirname "$LOG")"
  exec >>"$LOG" 2>&1
  echo; echo "===== $(date '+%Y-%m-%d %H:%M:%S') sauvegarde automatique ====="
fi

mkdir -p "$DEST/historique"
TMP="$(mktemp -d /tmp/pibackup.XXXXXX)"
SOCK="$TMP/ssh.sock"
cleanup() {
  rc=$?
  ssh -O exit -o ControlPath="$SOCK" "$HOST" >/dev/null 2>&1 || true
  rm -rf "$TMP"
  if [ "$AUTO" = 1 ] && [ "$rc" -ne 0 ]; then notify "Échec" "Voir ~/Library/Logs/homelab-backup.log"; fi
  exit "$rc"
}
trap cleanup EXIT

OPTS=(-o ControlMaster=auto -o ControlPath="$SOCK" -o ControlPersist=5m -o ConnectTimeout=15)
[ "$AUTO" = 1 ] && OPTS+=(-o BatchMode=yes)

# Contrôle d'exposition (Cloudflare Access) : indépendant du Pi, signalé à part de la sauvegarde.
CHECK="$(cd "$(dirname "$0")" && pwd)/verifier-acces.sh"
if [ -x "$CHECK" ]; then
  ACCESS_RC=0
  ACCESS_OUT="$("$CHECK" --quiet 2>&1)" || ACCESS_RC=$?
  if [ "$ACCESS_RC" = 1 ]; then
    echo "!! EXPOSITION DÉTECTÉE :"; echo "$ACCESS_OUT"
    notify "Exposition détectée" "$(echo "$ACCESS_OUT" | head -1 | cut -c1-110)"
  fi
fi

echo "Connexion au Pi..."
if ! ssh "${OPTS[@]}" "$HOST" true; then
  if [ "$AUTO" = 1 ]; then
    # Pi éteint, Mac hors du réseau local, réseau pas encore monté au réveil : on réessaiera à la prochaine heure.
    AGE="$(age_hours)"
    echo "Pi injoignable (dernière sauvegarde réussie il y a ${AGE} h) : nouvel essai au prochain passage."
    [ "$AGE" -ge "$ALERT_AGE_H" ] && notify "Pi injoignable" "Aucune sauvegarde réussie depuis plus de ${ALERT_AGE_H} h."
    exit 0
  fi
  echo "ERREUR : le Pi est injoignable."; exit 1
fi

echo "1/4 Instantané cohérent des bases sur le Pi"
RDIR="/var/backups/homelab"
SNAP_OUT=""
if SNAP_OUT="$(ssh "${OPTS[@]}" "$HOST" 'sudo -n /usr/local/sbin/homelab-backup' 2>&1)"; then
  echo "   (script root, sans mot de passe)"
elif [ "$AUTO" = 0 ] && [ -t 0 ] && echo "$SNAP_OUT" | grep -qiE "password is required|not found|No such file|not allowed|may not run"; then
  echo "   Script root non installé : repli interactif (mot de passe sudo du Pi)."
  echo "   Pour ne plus le saisir : sur le Pi, sudo bash ~/docker/pi/install-backup.sh"
  RDIR="/tmp"
  cat > "$TMP/remote.sh" <<'REMOTE'
set -euo pipefail
sudo -v
command -v sqlite3 >/dev/null || sudo apt-get install -y sqlite3 >/dev/null
D="$HOME/docker/uptime-kuma/data"
S="$(mktemp -d)"
sudo sqlite3 "$D/kuma.db" ".backup '$S/kuma.db'"
sudo cp "$D/db-config.json" "$S/db-config.json"
sudo chown -R "$USER" "$S"
tar czf /tmp/uptime-kuma-data.tgz -C "$S" kuma.db db-config.json
rm -rf "$S"
G="$HOME/docker/gamevault/data/catalog.db"
rm -f /tmp/gamevault-data.tgz
if [ -f "$G" ]; then
  GS="$(mktemp -d)"
  sudo sqlite3 "$G" ".backup '$GS/catalog.db'"
  sudo chown -R "$USER" "$GS"
  tar czf /tmp/gamevault-data.tgz -C "$GS" catalog.db
  rm -rf "$GS"
fi
REMOTE
  scp -q "${OPTS[@]}" "$TMP/remote.sh" "$HOST:/tmp/pi-backup.sh"
  ssh -t "${OPTS[@]}" "$HOST" 'bash /tmp/pi-backup.sh; rc=$?; rm -f /tmp/pi-backup.sh; exit $rc'
else
  echo "ERREUR : le script de sauvegarde du Pi a échoué :"; echo "$SNAP_OUT"
  exit 1
fi

echo "2/4 Téléchargement"
scp -q "${OPTS[@]}" "$HOST:$RDIR/uptime-kuma-data.tgz" "$TMP/uptime-kuma-data.tgz"
scp -q "${OPTS[@]}" "$HOST:docker/.env" "$TMP/.env"
HAS_GV=0
if scp -q "${OPTS[@]}" "$HOST:$RDIR/gamevault-data.tgz" "$TMP/gamevault-data.tgz" 2>/dev/null; then HAS_GV=1; fi
[ "$RDIR" = "/tmp" ] && ssh "${OPTS[@]}" "$HOST" 'rm -f /tmp/uptime-kuma-data.tgz /tmp/gamevault-data.tgz'

echo "3/4 Vérification"
mkdir "$TMP/x"
tar xzf "$TMP/uptime-kuma-data.tgz" -C "$TMP/x"
[ "$(sqlite3 "$TMP/x/kuma.db" 'PRAGMA integrity_check;')" = "ok" ] || { echo "ERREUR : base Uptime Kuma corrompue, rien n'a été remplacé."; exit 1; }
MON="$(sqlite3 "$TMP/x/kuma.db" 'SELECT count(*) FROM monitor;')"
NOTIF="$(sqlite3 "$TMP/x/kuma.db" 'SELECT count(*) FROM notification;')"
GAMES=""
if [ "$HAS_GV" = 1 ]; then
  mkdir "$TMP/gv"
  tar xzf "$TMP/gamevault-data.tgz" -C "$TMP/gv"
  [ "$(sqlite3 "$TMP/gv/catalog.db" 'PRAGMA integrity_check;')" = "ok" ] || { echo "ERREUR : base GameVault corrompue, rien n'a été remplacé."; exit 1; }
  GAMES="$(sqlite3 "$TMP/gv/catalog.db" 'SELECT count(*) FROM games;')"
else
  echo "   (pas de base GameVault sur le Pi : ignorée)"
fi
TOKENS="$(awk -F= '/^CLOUDFLARE_TUNNEL_TOKEN_/ && length($2) > 100 {n++} END {print n+0}' "$TMP/.env")"
[ "$TOKENS" -ge 1 ] || { echo "ERREUR : aucun token Cloudflare valide dans le .env reçu, rien n'a été remplacé."; exit 1; }
grep -q '^DOCKER_GID=' "$TMP/.env" || echo "   (remarque : pas de DOCKER_GID dans le .env, il sera recalculé à la restauration)"

echo "4/4 Enregistrement dans $DEST"
[ -f "$DEST/.env" ] && cp -p "$DEST/.env" "$DEST/.env.prev"
for f in uptime-kuma-data.tgz gamevault-data.tgz; do
  if [ -f "$DEST/$f" ]; then
    cp -p "$DEST/$f" "$DEST/historique/$(date -r "$DEST/$f" +%Y-%m-%d_%H%M)-$f"
    ls -1t "$DEST"/historique/*-"$f" 2>/dev/null | tail -n +$((KEEP + 1)) | while read -r old; do rm -f "$old"; done
  fi
done
install -m 600 "$TMP/.env" "$DEST/.env"
install -m 600 "$TMP/uptime-kuma-data.tgz" "$DEST/uptime-kuma-data.tgz"
[ "$HAS_GV" = 1 ] && install -m 600 "$TMP/gamevault-data.tgz" "$DEST/gamevault-data.tgz"
chmod 700 "$DEST/historique"; chmod 600 "$DEST"/historique/* 2>/dev/null || true

# Scripts de restauration : copiés depuis le dépôt du Pi, par remplacement atomique (ce script peut en faire partie).
for f in restore.sh mac/restaurer-pi.sh mac/sauvegarder-pi.sh mac/planifier-sauvegarde.sh mac/verifier-acces.sh; do
  if scp -q "${OPTS[@]}" "$HOST:docker/$f" "$TMP/script.new" 2>/dev/null && head -1 "$TMP/script.new" | grep -q '^#!'; then
    install -m 711 "$TMP/script.new" "$DEST/.$(basename "$f").new" && mv -f "$DEST/.$(basename "$f").new" "$DEST/$(basename "$f")"
  else
    echo "   (script non récupéré : $f, copie existante conservée)"
  fi
done
touch "$STAMP"

MSG="$TOKENS tokens Cloudflare, Uptime Kuma ($MON sondes, $NOTIF notification(s))${GAMES:+, GameVault ($GAMES jeux)}"
echo
echo "Sauvegarde terminée : $MSG."
echo "Ces fichiers contiennent des secrets : ne pas les versionner ni les partager."
if [ "$AUTO" = 1 ]; then notify "Terminée" "$MSG"; fi
