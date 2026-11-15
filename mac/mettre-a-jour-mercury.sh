#!/bin/bash
# Met à jour Mercury (dépôt privé maximelabatut/mercury : suivi des températures de la maison) sur le Pi.
#
#   mettre-a-jour-mercury.sh              met à jour si GitHub a de nouveaux commits (sinon : « Déjà à jour »)
#   mettre-a-jour-mercury.sh --verifier   dit seulement si le Pi est à jour, sans rien déployer
#   mettre-a-jour-mercury.sh --force      reconstruit et redéploie même si rien n'a changé
#
# Même principe que Dayshift : le dépôt est lu depuis le Mac (identifiants GitHub habituels), le Pi n'a aucun accès au dépôt.
# Depuis le Mac (git, node, rsync, SSH vers le Pi) :
#   1. clone ou met à jour le dépôt dans ~/.cache/homelab-jeux/mercury ;
#   2. compare au commit déployé (~/docker/mercury/.version sur le Pi) ; stop si identique ;
#   3. contrôle la syntaxe, et lance les tests si ce Mac a Node >= 22.5 ;
#   4. copie le nécessaire (Dockerfile, package*.json, server.mjs, lib/, public/, config/) dans ~/docker/mercury/app ;
#      JAMAIS .env, data/ ni la session Alexa : ils vivent dans ~/docker/mercury/data sur le Pi ;
#   5. reconstruit l'image et relance le conteneur `mercury` (ni les autres ni les tunnels ne sont touchés) ;
#   6. attend « healthy » et contrôle 127.0.0.1:8095/healthz.
# SSH_KEY_FILE=… impose la clé SSH.
set -euo pipefail

HOST="${MERCURY_HOST:-maxime@maxime.local}"
REPO="https://github.com/maximelabatut/mercury.git"
CACHE="${JEUX_CACHE:-$HOME/.cache/homelab-jeux}/mercury"
DEST="docker/mercury"

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
SSH_OPTS=(-o ConnectTimeout=10)
if [ -n "${SSH_KEY_FILE:-}" ]; then SSH_OPTS+=(-i "$SSH_KEY_FILE" -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new); fi
export RSYNC_RSH="ssh ${SSH_OPTS[*]}"
ssh_pi() { ssh "${SSH_OPTS[@]}" "$HOST" "$@"; }

ssh_pi true 2>/dev/null || { echo "Le Pi ($HOST) ne répond pas en SSH." >&2; exit 1; }

etape "1. Dépôt mercury (GitHub, privé)"
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

etape "2. Contrôles"
cd "$CACHE"
node --check server.mjs || { echo "server.mjs ne passe pas le contrôle de syntaxe : déploiement annulé (rien n'a été modifié sur le Pi)." >&2; exit 1; }
ok "node --check server.mjs"
if node -e 'process.exit(require("node:sqlite") ? 0 : 1)' 2>/dev/null; then
  node --disable-warning=ExperimentalWarning --test "test/*.test.mjs" >/dev/null 2>&1 \
    || { echo "Les tests échouent : déploiement annulé. Lancer « node --test test/*.test.mjs » dans $CACHE." >&2; exit 1; }
  ok "tests"
else
  echo "  - tests ignorés (Node >= 22.5 requis sur ce Mac)"
fi

etape "3. Copie des sources sur le Pi"
ssh_pi "mkdir -p ~/$DEST/app ~/$DEST/data"
rsync -a --delete Dockerfile package.json package-lock.json server.mjs lib public config "$HOST:$DEST/app/"
ok "copié dans ~/$DEST/app/ (aucun secret)"

etape "4. Construction de l'image"
ssh_pi "cd ~/docker && docker compose build mercury 2>&1 | tail -3"
ok "image construite"

etape "5. Relance et vérification"
ssh_pi "cd ~/docker && docker compose up -d --no-deps mercury 2>&1 | tail -2"
etat=""
for i in $(seq 1 30); do
  etat="$(ssh_pi "docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' mercury" 2>/dev/null || true)"
  [ "$etat" = "healthy" ] && break
  sleep 3
done
[ "$etat" = "healthy" ] || { echo "Le conteneur mercury n'est pas « healthy » (état : $etat) : voir « docker logs mercury »." >&2; exit 1; }
ok "conteneur mercury : healthy"
ssh_pi "curl -fsS -m 5 http://127.0.0.1:8095/healthz >/dev/null" || { echo "Pas de réponse sur 127.0.0.1:8095." >&2; exit 1; }
ok "http://127.0.0.1:8095/healthz répond"
if ssh_pi "test -s ~/$DEST/data/alexa-cookie.json"; then
  ok "session Alexa présente"
else
  echo "  ⚠ pas de session Alexa : déposer data/alexa-cookie.json (npm run alexa:login sur le Mac, puis scp) ; la météo fonctionne déjà."
fi
ssh_pi "printf '%s\n' '$COMMIT' > ~/$DEST/.version"

echo; echo "Mercury est à jour : $COMMIT — $SUJET"
echo "(le tunnel cloudflared-mercury n'a pas été touché)"
