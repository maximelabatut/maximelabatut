#!/bin/bash
# Met à jour Garden Brawl (salle de jeux, https://games.maximelabatut.com) depuis GitHub, sur le Pi.
#
#   mettre-a-jour-jeux.sh              met à jour si GitHub a de nouveaux commits (sinon : « déjà à jour »)
#   mettre-a-jour-jeux.sh --verifier   dit seulement si le site est à jour, sans rien déployer
#   mettre-a-jour-jeux.sh --force      reconstruit et redéploie même si rien n'a changé
#
# Ce que le script fait (depuis le Mac, il faut git, node, npm, rsync et la connexion SSH au Pi) :
#   1. clone ou met à jour le dépôt du jeu dans ~/.cache/homelab-jeux/gardenbrawl ;
#   2. compare le dernier commit à celui en ligne (fichier version.txt) ; stop si identique ;
#   3. installe les dépendances, lance les tests (le déploiement est ANNULÉ si un test échoue) ;
#   4. construit le jeu avec l'adresse du serveur de manettes (sans elle, plus de QR code dans le lobby) ;
#   5. si serveur/ ou manette/ ont changé : copie sur le Pi, reconstruit et relance gardenbrawl-manettes (AVANT le jeu,
#      pour qu'un jeu récent ne rencontre jamais un ancien serveur) ;
#   6. copie le jeu dans ~/docker/games/html/gardenbrawl/ ;
#   7. vérifie le site public (fichier du jeu, page manette, /manette/sante).
# Après la mise à jour : Cmd+Maj+R dans le navigateur pour contourner le cache.
# Après une restauration de la carte SD (--force) : restaurer-pi.sh le propose ; SSH_KEY_FILE=… impose la clé SSH.
set -euo pipefail

HOST="${JEUX_HOST:-maxime@maxime.local}"
REPO="https://github.com/maximelabatut/gardenbrawl.git"
SITE="https://games.maximelabatut.com"
URL_MANETTE="$SITE/manette"
CACHE="${JEUX_CACHE:-$HOME/.cache/homelab-jeux}/gardenbrawl"
DEST_JEU="docker/games/html/gardenbrawl"
DEST_MANETTES="docker/games/manettes"

MODE=maj
for arg in "$@"; do
  case "$arg" in
    --verifier) MODE=verifier ;;
    --force) MODE=force ;;
    -h|--help) sed -n '2,/^set -euo/p' "$0" | sed '$d'; exit 0 ;;
    *) echo "Option inconnue : $arg (voir --help)" >&2; exit 2 ;;
  esac
done

for cmd in git node npm rsync ssh curl; do
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

etape "1. Dépôt du jeu (GitHub)"
mkdir -p "$(dirname "$CACHE")"
if [ -d "$CACHE/.git" ]; then
  git -C "$CACHE" fetch -q origin
else
  git clone -q "$REPO" "$CACHE"
  git -C "$CACHE" fetch -q origin
fi
git -C "$CACHE" reset -q --hard origin/main
COMMIT="$(git -C "$CACHE" rev-parse --short HEAD)"
SUJET="$(git -C "$CACHE" log -1 --format=%s)"
MANETTES_HASH="$(git -C "$CACHE" rev-parse HEAD:serveur HEAD:manette | tr '\n' '-')"
ok "GitHub : $COMMIT — $SUJET"

EN_LIGNE="$(ssh_pi "cat $DEST_JEU/version.txt 2>/dev/null" || true)"
MANETTES_EN_LIGNE="$(ssh_pi "cat $DEST_MANETTES/.version 2>/dev/null" || true)"
if [ -n "$EN_LIGNE" ]; then
  ok "En ligne : $EN_LIGNE"
else
  ok "En ligne : version inconnue (premier déploiement avec ce script)"
fi

if [ "$EN_LIGNE" = "$COMMIT" ] && [ "$MODE" != force ]; then
  echo; echo "Déjà à jour ($COMMIT)."; exit 0
fi
if [ "$MODE" = verifier ]; then
  if [ -n "$EN_LIGNE" ] && git -C "$CACHE" cat-file -e "$EN_LIGNE^{commit}" 2>/dev/null; then
    RETARD="$(git -C "$CACHE" rev-list --count "$EN_LIGNE..HEAD")"
    echo; echo "Le site est en retard de $RETARD commit(s) :"
    git -C "$CACHE" log "$EN_LIGNE..HEAD" --format='  %h %s'
  else
    echo; echo "Le site n'est pas à jour (en ligne : ${EN_LIGNE:-inconnu}, GitHub : $COMMIT)."
  fi
  exit 1
fi

etape "2. Dépendances et tests"
cd "$CACHE"
npm ci --silent --no-audit --no-fund
if ! npm test --silent >/tmp/jeux-tests.log 2>&1; then
  tail -25 /tmp/jeux-tests.log >&2
  echo "Des tests échouent : déploiement annulé (rien n'a été modifié sur le Pi)." >&2
  exit 1
fi
ok "$(grep -E 'Tests ' /tmp/jeux-tests.log | sed 's/^ *//')"

etape "3. Construction du jeu"
rm -rf dist
VITE_URL_MANETTE="$URL_MANETTE" npm run build --silent >/tmp/jeux-build.log 2>&1 || { tail -20 /tmp/jeux-build.log >&2; exit 1; }
BUNDLE="$(basename "$(ls dist/assets/index-*.js | head -1)")"
if ! grep -q "${SITE#https://}/manette" "dist/assets/$BUNDLE"; then
  echo "L'adresse du serveur de manettes n'est pas dans le build : déploiement annulé." >&2
  exit 1
fi
printf '%s\n' "$COMMIT" > dist/version.txt
ok "Build $BUNDLE (adresse des manettes incluse)"

if [ "$MANETTES_HASH" != "$MANETTES_EN_LIGNE" ] || [ "$MODE" = force ]; then
  etape "4. Serveur de manettes (serveur/ ou manette/ ont changé)"
  rsync -a --delete --exclude node_modules serveur manette "$HOST:$DEST_MANETTES/"
  ssh_pi "cd ~/docker && docker compose build gardenbrawl-manettes >/dev/null 2>&1 && docker compose up -d gardenbrawl-manettes games >/dev/null 2>&1 && printf '%s\n' '$MANETTES_HASH' > ~/$DEST_MANETTES/.version"
  sleep 3
  [ "$(ssh_pi "docker inspect -f '{{.State.Status}}' gardenbrawl-manettes")" = "running" ] \
    || { echo "gardenbrawl-manettes ne tourne pas après la mise à jour : voir « docker logs gardenbrawl-manettes »." >&2; exit 1; }
  ok "gardenbrawl-manettes reconstruit et relancé"
else
  etape "4. Serveur de manettes"
  ok "inchangé (rien à faire)"
fi

etape "5. Déploiement du jeu"
rsync -a --delete dist/ "$HOST:$DEST_JEU/"
ok "copié dans ~/$DEST_JEU/"

etape "6. Vérification du site public"
EN_LIGNE_APRES="$(curl -fsS -m 20 "$SITE/gardenbrawl/" | grep -o 'index-[A-Za-z0-9_-]*\.js' | head -1)"
[ "$EN_LIGNE_APRES" = "$BUNDLE" ] && ok "page du jeu : $BUNDLE" || { echo "Le site sert $EN_LIGNE_APRES au lieu de $BUNDLE." >&2; exit 1; }
curl -fsS -m 20 -o /dev/null "$SITE/gardenbrawl/assets/$BUNDLE" && ok "fichier du jeu : 200"
[ "$(curl -fsS -m 20 "$SITE/manette/sante")" = "ok" ] && ok "serveur de manettes : /manette/sante = ok"
curl -fsS -m 20 -o /dev/null "$SITE/manette/?s=ABCD&e=A" && ok "page manette : 200"

echo; echo "Garden Brawl est à jour : $COMMIT — $SUJET"
echo "Pense à Cmd+Maj+R dans le navigateur."
