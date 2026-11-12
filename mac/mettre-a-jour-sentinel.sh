#!/bin/bash
# Met à jour Sentinel (dépôt privé maximelabatut/sentinel : armement/désarmement de la centrale d'alarme) sur le Pi.
#
#   mettre-a-jour-sentinel.sh              met à jour si GitHub a de nouveaux commits (sinon : « Déjà à jour »)
#   mettre-a-jour-sentinel.sh --verifier   dit seulement si le Pi est à jour, sans rien déployer
#   mettre-a-jour-sentinel.sh --force      reconstruit et redéploie même si rien n'a changé
#
# Le dépôt est privé : il est lu depuis le Mac (avec tes identifiants GitHub habituels) ; le Pi ne détient aucun accès
# au dépôt. Le script, depuis le Mac (git, python3, rsync et SSH vers le Pi requis) :
#   1. clone ou met à jour le dépôt dans ~/.cache/homelab-jeux/sentinel ;
#   2. compare le dernier commit à celui déployé (fichier ~/docker/sentinel/.version sur le Pi) ; stop si identique ;
#   3. contrôle la syntaxe Python (`py_compile`, le dépôt n'a pas de tests ; déploiement ANNULÉ en cas d'erreur) ;
#   4. copie uniquement requirements.txt et webapp/ dans ~/docker/sentinel/app (JAMAIS config.json, webapp.json,
#      mot-de-passe-web.txt ni actions.log : les secrets de la centrale ne quittent pas leur machine) ;
#   5. reconstruit l'image ; ne (re)lance le conteneur `sentinel` QUE si ~/docker/sentinel/data/config.json ET webapp.json existent
#      (sans eux le serveur s'arrête aussitôt) ;
#   6. attend que le conteneur soit « healthy ».
# Après une restauration de la carte SD (--force) : restaurer-pi.sh le propose ; SSH_KEY_FILE=… impose la clé SSH.
set -euo pipefail

HOST="${SENTINEL_HOST:-maxime@maxime.local}"
REPO="https://github.com/maximelabatut/sentinel.git"
CACHE="${JEUX_CACHE:-$HOME/.cache/homelab-jeux}/sentinel"
DEST="docker/sentinel"

MODE=maj
for arg in "$@"; do
  case "$arg" in
    --verifier) MODE=verifier ;;
    --force) MODE=force ;;
    -h|--help) sed -n '2,/^set -euo/p' "$0" | sed '$d'; exit 0 ;;
    *) echo "Option inconnue : $arg (voir --help)" >&2; exit 2 ;;
  esac
done

for cmd in git python3 rsync ssh; do
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

etape "1. Dépôt sentinel (GitHub, privé)"
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

etape "2. Contrôle de la syntaxe Python"
cd "$CACHE"
if ! python3 -m py_compile webapp/server.py webapp/setup.py 2>/tmp/sentinel-pycompile.log; then
  cat /tmp/sentinel-pycompile.log >&2
  echo "Erreur de syntaxe : déploiement annulé (rien n'a été modifié sur le Pi)." >&2
  exit 1
fi
find webapp -name __pycache__ -type d -prune -exec rm -rf {} + 2>/dev/null || true
ok "py_compile : aucune erreur"

etape "3. Copie des sources sur le Pi"
rsync -a --delete --exclude __pycache__ --exclude webapp.json --exclude actions.log --exclude config.json requirements.txt webapp "$HOST:$DEST/app/"
ok "copié dans ~/$DEST/app/ (requirements.txt, webapp/ ; aucun secret)"

etape "4. Construction de l'image"
ssh_pi "cd ~/docker && docker compose build sentinel 2>&1 | tail -3"
ok "image sentinel:local construite"

PRET="$(ssh_pi "[ -s ~/$DEST/data/config.json ] && [ -s ~/$DEST/data/webapp.json ] && echo oui || echo non")"
if [ "$PRET" != oui ]; then
  echo
  echo "config.json et/ou webapp.json absents sur le Pi : le conteneur n'est PAS démarré (il s'arrêterait aussitôt)."
  echo "À créer par toi sur le Pi (secrets de la centrale : jamais dans un chat) : voir ajouter-un-site.md, section Sentinel."
  ssh_pi "printf '%s\n' '$COMMIT' > ~/$DEST/.version"
  echo; echo "Image à jour ($COMMIT), en attente de la configuration."
  exit 0
fi

etape "5. Relance et vérification"
ssh_pi "cd ~/docker && docker compose up -d sentinel 2>&1 | tail -2"
for i in $(seq 1 30); do
  etat="$(ssh_pi "docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' sentinel" 2>/dev/null || true)"
  [ "$etat" = "healthy" ] && break
  sleep 4
done
[ "$etat" = "healthy" ] || { echo "Le conteneur sentinel n'est pas « healthy » (état : $etat) : voir « docker logs sentinel »." >&2; exit 1; }
ok "conteneur sentinel : healthy"
ssh_pi "printf '%s\n' '$COMMIT' > ~/$DEST/.version"

echo; echo "Sentinel est à jour : $COMMIT — $SUJET"
