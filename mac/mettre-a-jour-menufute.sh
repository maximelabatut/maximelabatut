#!/bin/bash
# Met à jour Menu Futé (dépôt privé maximelabatut/menufute) sur le Pi.
#
#   mettre-a-jour-menufute.sh              met à jour si GitHub a de nouveaux commits (sinon : « Déjà à jour »)
#   mettre-a-jour-menufute.sh --verifier   dit seulement si le Pi est à jour, sans rien déployer
#   mettre-a-jour-menufute.sh --force      reconstruit et redéploie même si rien n'a changé
#
# Le dépôt est privé : il est lu depuis le Mac (avec tes identifiants GitHub habituels) ; le Pi ne détient aucun accès
# au dépôt. Le script, depuis le Mac (git, node, npm, rsync et SSH vers le Pi requis) :
#   1. clone ou met à jour le dépôt dans ~/.cache/homelab-jeux/menufute ;
#   2. compare le dernier commit à celui déployé (fichier ~/docker/menufute/.version sur le Pi) ; stop si identique ;
#   3. installe les dépendances et lance les tests (déploiement ANNULÉ si l'un échoue) ;
#   4. copie uniquement ce qui sert à l'exécution (src/, public/, package*.json) dans ~/docker/menufute/app ;
#   5. reconstruit l'image et relance le conteneur `menufute` (la base ~/docker/menufute/data n'est jamais touchée) ;
#   6. attend que le conteneur soit « healthy » et vérifie /api/sync/status.
# La base (recettes) est dans ~/docker/menufute/data/recipes.db ; la synchro du catalogue se lance depuis l'application.
set -euo pipefail

HOST="${MENUFUTE_HOST:-maxime@maxime.local}"
REPO="https://github.com/maximelabatut/menufute.git"
CACHE="${JEUX_CACHE:-$HOME/.cache/homelab-jeux}/menufute"
DEST="docker/menufute"

MODE=maj
for arg in "$@"; do
  case "$arg" in
    --verifier) MODE=verifier ;;
    --force) MODE=force ;;
    -h|--help) sed -n '2,/^set -euo/p' "$0" | sed '$d'; exit 0 ;;
    *) echo "Option inconnue : $arg (voir --help)" >&2; exit 2 ;;
  esac
done

for cmd in git node npm rsync ssh; do
  command -v "$cmd" >/dev/null || { echo "Il manque « $cmd » sur ce Mac." >&2; exit 1; }
done

ok() { printf '  \033[32m✓\033[0m %s\n' "$*"; }
etape() { printf '\n\033[1m%s\033[0m\n' "$*"; }
ssh_pi() { ssh -o ConnectTimeout=10 "$HOST" "$@"; }

ssh_pi true 2>/dev/null || { echo "Le Pi ($HOST) ne répond pas en SSH." >&2; exit 1; }

etape "1. Dépôt menufute (GitHub, privé)"
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

etape "2. Dépendances et tests"
cd "$CACHE"
npm ci --silent --no-audit --no-fund
if ! npm test >/tmp/menufute-tests.log 2>&1; then
  tail -30 /tmp/menufute-tests.log >&2
  echo "Des tests échouent : déploiement annulé (rien n'a été modifié sur le Pi)." >&2
  exit 1
fi
ok "$(grep -E '^# (tests|pass|fail)' /tmp/menufute-tests.log | tr '\n' ' ')"

etape "3. Copie des sources sur le Pi"
rsync -a --delete package.json package-lock.json src public "$HOST:$DEST/app/"
ok "copié dans ~/$DEST/app/ (src, public, package*.json)"

etape "4. Construction de l'image et relance"
ssh_pi "cd ~/docker && docker compose build menufute 2>&1 | tail -3 && docker compose up -d menufute 2>&1 | tail -2"
for i in $(seq 1 30); do
  etat="$(ssh_pi "docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' menufute" 2>/dev/null || true)"
  [ "$etat" = "healthy" ] && break
  sleep 3
done
[ "$etat" = "healthy" ] || { echo "Le conteneur menufute n'est pas « healthy » (état : $etat) : voir « docker logs menufute »." >&2; exit 1; }
ok "conteneur menufute : healthy"

etape "5. Vérification"
STATUT="$(ssh_pi "curl -fsS -m 10 http://127.0.0.1:8090/api/sync/status")"
ok "API locale : $STATUT"
ssh_pi "printf '%s\n' '$COMMIT' > ~/$DEST/.version"

echo; echo "Menu Futé est à jour : $COMMIT — $SUJET"
