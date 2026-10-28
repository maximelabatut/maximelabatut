#!/bin/bash
# Met à jour Roborock Cleaner (dépôt privé maximelabatut/roborockcleaner, pilotage de l'aspirateur via Matter) sur le Pi.
#
#   mettre-a-jour-cleaner.sh              met à jour si GitHub a de nouveaux commits (sinon : « Déjà à jour »)
#   mettre-a-jour-cleaner.sh --verifier   dit seulement si le Pi est à jour, sans rien déployer
#   mettre-a-jour-cleaner.sh --force      reconstruit et redéploie même si rien n'a changé
#
# Le dépôt est privé : il est lu depuis le Mac (avec tes identifiants GitHub habituels) ; le Pi ne détient aucun accès
# au dépôt. Le script, depuis le Mac (git, node, npm, rsync et SSH vers le Pi requis) :
#   1. clone ou met à jour le dépôt dans ~/.cache/homelab-jeux/roborockcleaner ;
#   2. compare le dernier commit à celui déployé (fichier ~/docker/cleaner/.version sur le Pi) ; stop si identique ;
#   3. installe les dépendances et lance le contrôle de types `npm run typecheck` (le dépôt n'a pas de tests ;
#      déploiement ANNULÉ si le contrôle échoue) ;
#   4. copie uniquement ce qui sert à l'exécution (src/, public/, tsconfig.json, package*.json) dans ~/docker/cleaner/app ;
#      JAMAIS le jumelage Matter (.matter-storage), le jeton (.api-token) ni mapper/ : ces secrets ne quittent pas leur machine ;
#   5. reconstruit l'image ; ne (re)lance le conteneur `cleaner` QUE si le jumelage Matter existe sur le Pi
#      (~/docker/cleaner/matter-storage non vide) : sans appareil jumelé le serveur s'arrête aussitôt ;
#   6. attend que le conteneur soit « healthy » (la connexion à l'aspirateur peut prendre une minute).
# Après une restauration de la carte SD (--force) : restaurer-pi.sh le propose ; SSH_KEY_FILE=… impose la clé SSH.
set -euo pipefail

HOST="${CLEANER_HOST:-maxime@maxime.local}"
REPO="https://github.com/maximelabatut/roborockcleaner.git"
CACHE="${JEUX_CACHE:-$HOME/.cache/homelab-jeux}/roborockcleaner"
DEST="docker/cleaner"

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
# Clé SSH explicite (utilisée par restaurer-pi.sh après une restauration) : SSH_KEY_FILE=~/.ssh/id_ed25519_homelab
SSH_OPTS=(-o ConnectTimeout=10)
if [ -n "${SSH_KEY_FILE:-}" ]; then SSH_OPTS+=(-i "$SSH_KEY_FILE" -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new); fi
export RSYNC_RSH="ssh ${SSH_OPTS[*]}"
ssh_pi() { ssh "${SSH_OPTS[@]}" "$HOST" "$@"; }

ssh_pi true 2>/dev/null || { echo "Le Pi ($HOST) ne répond pas en SSH." >&2; exit 1; }

etape "1. Dépôt roborockcleaner (GitHub, privé)"
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

etape "2. Dépendances et contrôle de types"
cd "$CACHE"
npm ci --silent --no-audit --no-fund
if ! npm run typecheck >/tmp/cleaner-typecheck.log 2>&1; then
  tail -30 /tmp/cleaner-typecheck.log >&2
  echo "Le contrôle de types échoue : déploiement annulé (rien n'a été modifié sur le Pi)." >&2
  exit 1
fi
ok "typecheck (tsc --noEmit) : aucune erreur"

etape "3. Copie des sources sur le Pi"
rsync -a --delete package.json package-lock.json tsconfig.json src public "$HOST:$DEST/app/"
ok "copié dans ~/$DEST/app/ (src, public, tsconfig.json, package*.json ; aucun secret)"

etape "4. Construction de l'image"
ssh_pi "cd ~/docker && docker compose build cleaner 2>&1 | tail -3"
ok "image cleaner:local construite"

JUMELE="$(ssh_pi "[ -n \"\$(ls -A ~/$DEST/matter-storage 2>/dev/null)\" ] && echo oui || echo non")"
if [ "$JUMELE" != oui ]; then
  echo
  echo "Jumelage Matter absent sur le Pi : le conteneur n'est PAS démarré (il s'arrêterait aussitôt)."
  echo "Pour jumeler (dans Apple Maison : accessoire > Réglages > « Activer le mode de jumelage »), puis sur le Pi :"
  echo "  cd ~/docker && docker compose run --rm cleaner npm run pair -- <code MT:… ou 11 chiffres>"
  echo "  docker compose up -d cleaner"
  ssh_pi "printf '%s\n' '$COMMIT' > ~/$DEST/.version"
  echo; echo "Image à jour ($COMMIT), en attente du jumelage."
  exit 0
fi

etape "5. Relance et vérification"
ssh_pi "cd ~/docker && docker compose up -d cleaner 2>&1 | tail -2"
for i in $(seq 1 50); do
  etat="$(ssh_pi "docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' cleaner" 2>/dev/null || true)"
  [ "$etat" = "healthy" ] && break
  sleep 4
done
[ "$etat" = "healthy" ] || { echo "Le conteneur cleaner n'est pas « healthy » (état : $etat) : voir « docker logs cleaner »." >&2; exit 1; }
ok "conteneur cleaner : healthy"
ssh_pi "printf '%s\n' '$COMMIT' > ~/$DEST/.version"

echo; echo "Roborock Cleaner est à jour : $COMMIT — $SUJET"
