#!/bin/bash
# Met à jour Sentinel (dépôt privé maximelabatut/sentinel : armement/désarmement de la centrale d'alarme) sur le Pi.
#
#   mettre-a-jour-sentinel.sh              met à jour si GitHub a de nouveaux commits (sinon : « Déjà à jour »)
#   mettre-a-jour-sentinel.sh --verifier   dit seulement si le Pi est à jour (et liste les commits en retard), sans rien déployer
#   mettre-a-jour-sentinel.sh --force      reconstruit et redéploie même si rien n'a changé
#
# Le dépôt est privé : il est lu depuis le Mac (avec tes identifiants GitHub habituels) ; le Pi ne détient aucun accès
# au dépôt. Application SENSIBLE (alarme) : le service en marche n'est touché qu'APRÈS validation du nouveau code.
# Le script, depuis le Mac (git, rsync et SSH vers le Pi requis ; pas de Python nécessaire sur le Mac) :
#   1. clone ou met à jour le dépôt dans ~/.cache/homelab-jeux/sentinel ;
#   2. compare le dernier commit à celui déployé (fichier ~/docker/sentinel/.version sur le Pi) ; stop si identique ;
#   3. copie requirements.txt et webapp/ dans ~/docker/sentinel/candidate (JAMAIS config.json, webapp.json,
#      mot-de-passe-web.txt ni actions.log : les secrets de la centrale ne quittent pas leur machine) ;
#   4. construit une image candidate et exécute, dans un conteneur jetable SANS réseau ni secrets (utilisateur root du conteneur jetable, même Python 3.11 que la
#      production), la compilation de webapp/ et les tests webapp/test_*.py : au moindre échec, tout s'arrête et le
#      service en marche n'a pas été touché ;
#   5. bascule : candidate -> app, image précédente conservée sous le nom sentinel:previous, reconstruction ;
#   6. ne (re)lance `sentinel` QUE si ~/docker/sentinel/data/config.json ET webapp.json existent, attend « healthy » et,
#      si le nouveau conteneur n'est pas sain, REVIENT AUTOMATIQUEMENT à l'image précédente.
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

for cmd in git rsync ssh; do
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

etape "2. Copie des sources dans un dossier candidat (le service en marche n'est pas touché)"
cd "$CACHE"
ssh_pi "rm -rf ~/$DEST/candidate && mkdir -p ~/$DEST/candidate"
rsync -a --delete --exclude __pycache__ --exclude webapp.json --exclude actions.log --exclude config.json requirements.txt webapp "$HOST:$DEST/candidate/"
ok "copié dans ~/$DEST/candidate/ (requirements.txt, webapp/ ; aucun secret)"

etape "3. Image candidate et contrôles dans un conteneur jetable (sans réseau, sans secrets)"
ssh_pi "docker build -q -t sentinel:candidate -f ~/$DEST/Dockerfile ~/$DEST/candidate >/dev/null" \
  || { echo "La construction de l'image candidate échoue : rien n'a été modifié sur le service." >&2; ssh_pi "rm -rf ~/$DEST/candidate"; exit 1; }
ok "image sentinel:candidate construite"
if ! ssh_pi "docker run --rm --user root --network none -e PYTHONDONTWRITEBYTECODE=1 sentinel:candidate sh -c 'python -m compileall -q webapp && for t in webapp/test_*.py; do [ -e \"\$t\" ] || continue; echo \"== \$t\"; python \"\$t\" || exit 1; done'" >/tmp/sentinel-controles.log 2>&1; then
  tail -30 /tmp/sentinel-controles.log >&2
  echo "Les contrôles échouent : déploiement annulé (le service en marche n'a pas été touché)." >&2
  ssh_pi "docker rmi sentinel:candidate >/dev/null 2>&1; rm -rf ~/$DEST/candidate"
  exit 1
fi
ok "compilation et tests : $(grep -E 'tests réussis' /tmp/sentinel-controles.log | tr '\n' ' ')"

etape "4. Basculement"
ssh_pi "docker tag sentinel:local sentinel:previous 2>/dev/null || true; rm -rf ~/$DEST/app && mv ~/$DEST/candidate ~/$DEST/app && cd ~/docker && docker compose build sentinel 2>&1 | tail -2 && docker rmi sentinel:candidate >/dev/null 2>&1 || true"
ok "sources en place dans ~/$DEST/app, image sentinel:local reconstruite (précédente : sentinel:previous)"

PRET="$(ssh_pi "[ -s ~/$DEST/data/config.json ] && [ -s ~/$DEST/data/webapp.json ] && echo oui || echo non")"
if [ "$PRET" != oui ]; then
  echo
  echo "config.json et/ou webapp.json absents sur le Pi : le conteneur n'est PAS démarré (il s'arrêterait aussitôt)."
  echo "À créer par toi sur le Pi (secrets de la centrale : jamais dans un chat) : voir ajouter-un-site.md, section Sentinel."
  ssh_pi "printf '%s\n' '$COMMIT' > ~/$DEST/.version"
  echo; echo "Image à jour ($COMMIT), en attente de la configuration."
  exit 0
fi

etape "5. Relance et vérification (retour arrière automatique en cas d'échec)"
ssh_pi "cd ~/docker && docker compose up -d sentinel 2>&1 | tail -2"
etat=""
for i in $(seq 1 30); do
  etat="$(ssh_pi "docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' sentinel" 2>/dev/null || true)"
  [ "$etat" = "healthy" ] && break
  sleep 4
done
if [ "$etat" != "healthy" ]; then
  echo "Le conteneur sentinel n'est pas « healthy » (état : $etat) : retour à l'image précédente." >&2
  if ssh_pi "docker image inspect sentinel:previous >/dev/null 2>&1 && docker tag sentinel:previous sentinel:local && cd ~/docker && docker compose up -d --no-build --force-recreate sentinel >/dev/null 2>&1"; then
    echo "Retour arrière effectué : l'ancienne version tourne de nouveau. Diagnostic : « docker logs sentinel » (la version défectueuse n'est pas marquée comme déployée)." >&2
  else
    echo "RETOUR ARRIÈRE IMPOSSIBLE (pas d'image précédente) : voir « docker logs sentinel »." >&2
  fi
  exit 1
fi
ok "conteneur sentinel : healthy"
ssh_pi "printf '%s\n' '$COMMIT' > ~/$DEST/.version"

echo; echo "Sentinel est à jour : $COMMIT — $SUJET"
