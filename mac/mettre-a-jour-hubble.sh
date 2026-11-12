#!/bin/bash
# Met à jour Hubble / Maison (dépôt privé maximelabatut/hubble, application iPhone : alarme, aspirateur, caméras) sur le Pi.
#
#   mettre-a-jour-hubble.sh              met à jour si GitHub a de nouveaux commits (sinon : « Déjà à jour »)
#   mettre-a-jour-hubble.sh --verifier   dit seulement si le Pi est à jour, sans rien déployer
#   mettre-a-jour-hubble.sh --force      reconstruit et redéploie même si rien n'a changé
#
# Le dépôt est privé : il est lu depuis le Mac (avec tes identifiants GitHub habituels) ; le Pi ne détient aucun accès
# au dépôt. Le script, depuis le Mac (git, node 20+, rsync et SSH vers le Pi requis) :
#   1. clone ou met à jour le dépôt dans ~/.cache/homelab-jeux/hubble ;
#   2. compare le dernier commit à celui déployé (fichier ~/docker/maison/.version sur le Pi) ; stop si identique ;
#   3. lance les tests (`node --test test/`, contre de FAUX services : rien ne touche l'alarme ni l'aspirateur ;
#      déploiement ANNULÉ si un test échoue) ; l'application n'a aucune dépendance npm ;
#   4. copie uniquement ce qui sert à l'exécution (server.mjs, lib/, public/, package.json, Dockerfile) dans ~/docker/maison/app ;
#      JAMAIS le fichier du mot de passe de Sentinel (SENTINEL_PASSWORD_FILE), qui reste sur le Pi ;
#   5. reconstruit l'image et relance le conteneur `maison` (sans toucher aux autres ni au tunnel `cloudflared-hubble`) ;
#   6. attend que le conteneur soit « healthy » et contrôle /healthz sur 127.0.0.1:8093.
# Après une restauration de la carte SD (--force) : restaurer-pi.sh le propose ; SSH_KEY_FILE=… impose la clé SSH.
set -euo pipefail

HOST="${HUBBLE_HOST:-maxime@maxime.local}"
REPO="https://github.com/maximelabatut/hubble.git"
CACHE="${JEUX_CACHE:-$HOME/.cache/homelab-jeux}/hubble"
DEST="docker/maison"

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

etape "1. Dépôt hubble (GitHub, privé)"
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

etape "2. Tests (faux services, rien ne touche le vrai matériel)"
cd "$CACHE"
LOG="$(mktemp)"
if ! node --test test/ >"$LOG" 2>&1; then
  tail -40 "$LOG" >&2
  rm -f "$LOG"
  echo "Des tests échouent : déploiement annulé (rien n'a été modifié sur le Pi)." >&2
  exit 1
fi
ok "$(grep -E '^# pass' "$LOG" | sed 's/# pass /tests réussis : /')"
rm -f "$LOG"

etape "3. Copie des sources sur le Pi"
ssh_pi "mkdir -p ~/$DEST/app"
rsync -a --delete server.mjs package.json Dockerfile .dockerignore lib public "$HOST:$DEST/app/"
ok "copié dans ~/$DEST/app/ (server.mjs, lib, public, package.json, Dockerfile ; aucun secret)"

etape "4. Construction de l'image"
ssh_pi "cd ~/docker && docker compose build maison 2>&1 | tail -3"
ok "image maison:local construite"

etape "5. Relance et vérification"
ssh_pi "cd ~/docker && docker compose up -d --no-deps maison 2>&1 | tail -2"
etat=""
for i in $(seq 1 30); do
  etat="$(ssh_pi "docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' maison" 2>/dev/null || true)"
  [ "$etat" = "healthy" ] && break
  sleep 3
done
[ "$etat" = "healthy" ] || { echo "Le conteneur maison n'est pas « healthy » (état : $etat) : voir « docker logs maison »." >&2; exit 1; }
ok "conteneur maison : healthy"
ssh_pi "curl -fsS -m 5 http://127.0.0.1:8093/healthz >/dev/null" || { echo "/healthz ne répond pas sur 127.0.0.1:8093." >&2; exit 1; }
ok "http://127.0.0.1:8093/healthz répond"
ssh_pi "printf '%s\n' '$COMMIT' > ~/$DEST/.version"

echo; echo "Hubble / Maison est à jour : $COMMIT — $SUJET"
echo "(le tunnel cloudflared-hubble n'a pas été touché)"
