#!/bin/bash
# À lancer depuis le Mac, Pi allumé : copie sur le Mac le .env et les données d'Uptime Kuma.
#   ~/Desktop/raspberrypi/.env                     tokens Cloudflare (+ DOCKER_GID, recalculé à la restauration)
#   ~/Desktop/raspberrypi/uptime-kuma-data.tgz     base SQLite cohérente + db-config.json
#   ~/Desktop/raspberrypi/gamevault-data.tgz       base SQLite de GameVault (catalog.db), instantané cohérent
# Les versions précédentes sont conservées en .prev. Le mot de passe du Pi est demandé pour SSH, puis pour sudo.
set -euo pipefail

HOST="maxime@maxime.local"
DEST="${DEST:-$HOME/Desktop/raspberrypi}"
mkdir -p "$DEST"

TMP="$(mktemp -d /tmp/pibackup.XXXXXX)"
SOCK="$TMP/ssh.sock"
trap 'ssh -O exit -o ControlPath="$SOCK" "$HOST" >/dev/null 2>&1 || true; rm -rf "$TMP"' EXIT
OPTS=(-o ControlMaster=auto -o ControlPath="$SOCK" -o ControlPersist=5m)

echo "Connexion au Pi (mot de passe de l'utilisateur maxime)..."
ssh "${OPTS[@]}" "$HOST" true

echo "1/4 Instantané cohérent d'Uptime Kuma sur le Pi (le mot de passe sudo est identique à celui du Pi)"
# .backup tient compte du journal WAL (une simple copie de kuma.db perdrait les écritures récentes).
# Exécuté avec un terminal (ssh -t) car sudo demande un mot de passe sur ce Pi.
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

echo "2/4 Téléchargement"
scp -q "${OPTS[@]}" "$HOST:/tmp/uptime-kuma-data.tgz" "$TMP/uptime-kuma-data.tgz"
scp -q "${OPTS[@]}" "$HOST:docker/.env" "$TMP/.env"
HAS_GV=0
if scp -q "${OPTS[@]}" "$HOST:/tmp/gamevault-data.tgz" "$TMP/gamevault-data.tgz" 2>/dev/null; then HAS_GV=1; fi
ssh "${OPTS[@]}" "$HOST" 'rm -f /tmp/uptime-kuma-data.tgz /tmp/gamevault-data.tgz'

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
  echo "   (pas de base GameVault sur le Pi : ~/docker/gamevault/data/catalog.db absent, ignorée)"
fi
TOKENS="$(awk -F= '/^CLOUDFLARE_TUNNEL_TOKEN_/ && length($2) > 100 {n++} END {print n+0}' "$TMP/.env")"
[ "$TOKENS" -ge 1 ] || { echo "ERREUR : aucun token Cloudflare valide dans le .env reçu, rien n'a été remplacé."; exit 1; }
grep -q '^DOCKER_GID=' "$TMP/.env" || echo "   (remarque : pas de DOCKER_GID dans le .env, il sera recalculé à la restauration)"

echo "4/4 Enregistrement dans $DEST"
for f in .env uptime-kuma-data.tgz gamevault-data.tgz; do
  [ -f "$DEST/$f" ] && cp -p "$DEST/$f" "$DEST/$f.prev"
done
install -m 600 "$TMP/.env" "$DEST/.env"
install -m 600 "$TMP/uptime-kuma-data.tgz" "$DEST/uptime-kuma-data.tgz"
[ "$HAS_GV" = 1 ] && install -m 600 "$TMP/gamevault-data.tgz" "$DEST/gamevault-data.tgz"

echo
echo "Sauvegarde terminée : $TOKENS tokens Cloudflare, Uptime Kuma ($MON sondes, $NOTIF notification(s))${GAMES:+, GameVault ($GAMES jeux)}."
echo "Ces fichiers contiennent des secrets : ne pas les versionner ni les partager."
