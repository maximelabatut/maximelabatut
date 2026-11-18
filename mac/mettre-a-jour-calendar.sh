#!/bin/bash
# Met à jour « Calendar » (dépôt privé maximelabatut/calendar : planning périscolaire, menus de cantine et factures du portail famille
# de la mairie, pour l'enfant de l'utilisateur) sur le Pi.
#
#   mettre-a-jour-calendar.sh              met à jour si GitHub a de nouveaux commits (sinon : « Déjà à jour »)
#   mettre-a-jour-calendar.sh --verifier   dit seulement si le Pi est à jour, sans rien déployer
#   mettre-a-jour-calendar.sh --force      reconstruit et redéploie même si rien n'a changé
#
# Le dépôt est privé : il est lu depuis le Mac (identifiants GitHub habituels) ; le Pi n'a aucun accès au dépôt.
# Depuis le Mac (git, node, rsync et SSH vers le Pi requis) :
#   1. clone ou met à jour le dépôt dans ~/.cache/homelab-jeux/calendar ;
#   2. compare au commit déployé (~/docker/calendar/.version sur le Pi) ; stop si identique ;
#   3. contrôle la syntaxe (`node --check src/*.js`) : le dépôt n'a ni tests ni dépendances ;
#   4. copie uniquement le nécessaire (src/, package.json) dans ~/docker/calendar/app ;
#      JAMAIS .env ni data/ (identifiants du portail, mot de passe de la page, historique, factures) : ils vivent dans
#      ~/docker/calendar/data sur le Pi ;
#   5. reconstruit l'image ; ne (re)lance le conteneur `calendar` QUE si ~/docker/calendar/data/.env existe (identifiants du
#      portail) ; le tunnel `cloudflared-calendar` n'est jamais touché ;
#   6. attend « healthy » et contrôle 127.0.0.1:8096/healthz (200).
# SSH_KEY_FILE=… impose la clé SSH.
set -euo pipefail

HOST="${CALENDAR_HOST:-maxime@maxime.local}"
REPO="https://github.com/maximelabatut/calendar.git"
CACHE="${JEUX_CACHE:-$HOME/.cache/homelab-jeux}/calendar"
DEST="docker/calendar"

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

etape "1. Dépôt calendar (GitHub, privé)"
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
for f in src/*.js; do
  node --check "$f" || { echo "$f ne passe pas le contrôle de syntaxe : déploiement annulé (rien n'a été modifié sur le Pi)." >&2; exit 1; }
done
ok "node --check src/*.js"

etape "3. Copie des sources sur le Pi"
ssh_pi "mkdir -p ~/$DEST/app"
rsync -a --delete src package.json "$HOST:$DEST/app/"
ok "copié dans ~/$DEST/app/ (src, package.json ; aucun secret)"

etape "4. Construction de l'image"
ssh_pi "cd ~/docker && docker compose build calendar 2>&1 | tail -3"
ok "image calendar:local construite"

etape "5. Relance et vérification"
if ! ssh_pi "test -s ~/$DEST/data/.env"; then
  echo "  ⚠ ~/docker/calendar/data/.env absent : image construite, conteneur NON démarré (identifiants du portail absents)."
  echo "    Déposer data/.env (PORTAIL_EMAIL, PORTAIL_PASSWORD ; droits 600), puis relancer ce script avec --force."
  exit 0
fi
ssh_pi "cd ~/docker && docker compose up -d --no-deps calendar 2>&1 | tail -2"
etat=""
for i in $(seq 1 30); do
  etat="$(ssh_pi "docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' calendar" 2>/dev/null || true)"
  [ "$etat" = "healthy" ] && break
  sleep 3
done
[ "$etat" = "healthy" ] || { echo "Le conteneur calendar n'est pas « healthy » (état : $etat) : voir « docker logs calendar »." >&2; exit 1; }
ok "conteneur calendar : healthy"
code="$(ssh_pi "curl -s -o /dev/null -m 10 -w '%{http_code}' http://127.0.0.1:8096/healthz" || true)"
[ "$code" = "200" ] || { echo "127.0.0.1:8096/healthz répond $code (attendu : 200)." >&2; exit 1; }
ok "http://127.0.0.1:8096/healthz répond 200"
ssh_pi "printf '%s\n' '$COMMIT' > ~/$DEST/.version"

echo; echo "Calendar est à jour : $COMMIT — $SUJET"
echo "(le tunnel cloudflared-calendar n'a pas été touché)"
