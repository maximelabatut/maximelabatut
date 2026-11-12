#!/bin/bash
# Met à jour Dayshift (dépôt privé maximelabatut/dayshift : webapp de contrôle des volets Somfy, API locale d'une TaHoma Switch) sur le Pi.
#
#   mettre-a-jour-dayshift.sh              met à jour si GitHub a de nouveaux commits (sinon : « Déjà à jour »)
#   mettre-a-jour-dayshift.sh --verifier   dit seulement si le Pi est à jour, sans rien déployer
#   mettre-a-jour-dayshift.sh --force      reconstruit et redéploie même si rien n'a changé
#
# Le dépôt est privé : il est lu depuis le Mac (avec tes identifiants GitHub habituels) ; le Pi ne détient aucun accès
# au dépôt. Le script, depuis le Mac (git, node, rsync et SSH vers le Pi requis) :
#   1. clone ou met à jour le dépôt dans ~/.cache/homelab-jeux/dayshift ;
#   2. compare le dernier commit à celui déployé (fichier ~/docker/dayshift/.version sur le Pi) ; stop si identique ;
#   3. contrôle la syntaxe (`node --check server.js`) : le dépôt n'a pas de tests, et aucune dépendance npm ;
#   4. copie uniquement ce qui sert à l'exécution (server.js, package.json, public/) dans ~/docker/dayshift/app ;
#      JAMAIS .env ni rooms.json (jeton de la box et pièces) : ils vivent dans ~/docker/dayshift/data sur le Pi ;
#   5. reconstruit l'image et relance le conteneur `dayshift` (sans toucher aux autres ni au tunnel `cloudflared-dayshift`) ;
#   6. attend que le conteneur soit « healthy » et contrôle la page sur 127.0.0.1:8094 ; dit si l'application est en MODE DÉMO
#      (pas de ~/docker/dayshift/data/.env : faux volets, rien ne bouge).
# Après une restauration de la carte SD (--force) : restaurer-pi.sh le propose ; SSH_KEY_FILE=… impose la clé SSH.
set -euo pipefail

HOST="${DAYSHIFT_HOST:-maxime@maxime.local}"
REPO="https://github.com/maximelabatut/dayshift.git"
CACHE="${JEUX_CACHE:-$HOME/.cache/homelab-jeux}/dayshift"
DEST="docker/dayshift"

MODE=maj
for arg in "$@"; do
  case "$arg" in
    --verifier) MODE=verifier ;;
    --force) MODE=force ;;
    -h|--help) sed -n '2,/^set -euo/p' "$0" | sed '$d'; exit 0 ;;
    *) echo "Option inconnue : $arg (voir --help)" >&2; exit 2 ;;
  esac
done

for cmd in git node rsync ssh; do
  command -v "$cmd" >/dev/null || { echo "Il manque « $cmd » sur ce Mac." >&2; exit 1; }
done

ok() { printf '  \033[32m✓\033[0m %s\n' "$*"; }
etape() { printf '\n\033[1m%s\033[0m\n' "$*"; }
# Clé SSH explicite (utilisée par restaurer-pi.sh après une restauration) : SSH_KEY_FILE=~/.ssh/id_ed25519_homelab
SSH_OPTS=(-o ConnectTimeout=10)
if [ -n "${SSH_KEY_FILE:-}" ]; then SSH_OPTS+=(-i "$SSH_KEY_FILE" -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new); fi
export RSYNC_RSH="ssh ${SSH_OPTS[*]}"
ssh_pi() { ssh "${SSH_OPTS[@]}" "$HOST" "$@"; }

ssh_pi true 2>/dev/null || { echo "Le Pi ($HOST) ne répond pas en SSH." >&2; exit 1; }

etape "1. Dépôt dayshift (GitHub, privé)"
mkdir -p "$(dirname "$CACHE")"
if [ ! -d "$CACHE/.git" ]; then
  git clone -q "$REPO" "$CACHE" || { echo "Clone impossible : identifiants GitHub du Mac requis (dépôt privé)." >&2; exit 1; }
fi
git -C "$CACHE" fetch -q origin
git -C "$CACHE" reset -q --hard origin/main
COMMIT="$(git -C "$CACHE" rev-parse --short HEAD)"
SUJET="$(git -C "$CACHE" log -1 --format=%s)"
ok "GitHub : $COMMIT — $SUJET"

DEPLOYE="$(ssh_pi "cat ~/$DEST/.version 2>/dev/null" || true)"
ok "Sur le Pi : ${DEPLOYE:-aucune version déployée}"

if [ "$DEPLOYE" = "$COMMIT" ] && [ "$MODE" != force ]; then
  echo; echo "Déjà à jour ($COMMIT)."; exit 0
fi
if [ "$MODE" = verifier ]; then
  if [ -n "$DEPLOYE" ] && git -C "$CACHE" cat-file -e "$DEPLOYE^{commit}" 2>/dev/null; then
    echo; echo "Le Pi est en retard de $(git -C "$CACHE" rev-list --count "$DEPLOYE..HEAD") commit(s) :"
    git -C "$CACHE" log "$DEPLOYE..HEAD" --format='  %h %s'
  else
    echo; echo "Le Pi n'est pas à jour (déployé : ${DEPLOYE:-rien}, GitHub : $COMMIT)."
  fi
  exit 1
fi

etape "2. Contrôle de syntaxe"
cd "$CACHE"
node --check server.js || { echo "server.js ne passe pas le contrôle de syntaxe : déploiement annulé (rien n'a été modifié sur le Pi)." >&2; exit 1; }
ok "node --check server.js"

etape "3. Copie des sources sur le Pi"
ssh_pi "mkdir -p ~/$DEST/app"
rsync -a --delete server.js package.json public "$HOST:$DEST/app/"
ok "copié dans ~/$DEST/app/ (server.js, public, package.json ; aucun secret)"

etape "4. Construction de l'image"
ssh_pi "cd ~/docker && docker compose build dayshift 2>&1 | tail -3"
ok "image dayshift:local construite"

etape "5. Relance et vérification"
ssh_pi "cd ~/docker && docker compose up -d --no-deps dayshift 2>&1 | tail -2"
etat=""
for i in $(seq 1 30); do
  etat="$(ssh_pi "docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' dayshift" 2>/dev/null || true)"
  [ "$etat" = "healthy" ] && break
  sleep 3
done
[ "$etat" = "healthy" ] || { echo "Le conteneur dayshift n'est pas « healthy » (état : $etat) : voir « docker logs dayshift »." >&2; exit 1; }
ok "conteneur dayshift : healthy"
ssh_pi "curl -fsS -m 5 http://127.0.0.1:8094/ >/dev/null" || { echo "La page ne répond pas sur 127.0.0.1:8094." >&2; exit 1; }
ok "http://127.0.0.1:8094/ répond"
if ssh_pi "docker logs dayshift 2>&1 | grep -q 'MODE DÉMO'"; then
  echo "  ⚠ MODE DÉMO : pas de ~/docker/dayshift/data/.env (GATEWAY_HOST, GATEWAY_TOKEN) : les volets affichés sont faux."
else
  ok "connecté à la box (pas en mode démo)"
fi
ssh_pi "printf '%s\n' '$COMMIT' > ~/$DEST/.version"

echo; echo "Dayshift est à jour : $COMMIT — $SUJET"
echo "(le tunnel cloudflared-dayshift n'a pas été touché)"
