#!/bin/bash
# Restauration du Pi depuis la dernière sauvegarde chiffrée (dépôt GitHub privé), ou test de cette restauration.
#
#   restaurer-pi.sh [archive.tar.gz.age]     restaure un Pi fraîchement flashé (Raspberry Pi Imager) et démarré sur le WiFi
#   restaurer-pi.sh --verifier [archive]     TEST À BLANC, sans Pi : déchiffre la dernière archive et contrôle qu'elle est
#                                            restaurable (fraîcheur, bases, tokens, clés de déploiement). À lancer de temps en temps.
#
# Archive : sans argument, la dernière est clonée avec la clé SSH ~/.ssh/id_ed25519_homelab (enregistrée comme « deploy key »
# en lecture seule du dépôt de sauvegardes), à défaut en HTTPS (identifiants GitHub). Ou la télécharger depuis la page GitHub
# du dépôt et passer son chemin en argument.
# Déchiffrement : avec cette même clé (age demande sa phrase secrète au terminal), ou toute autre indiquée par AGE_KEY_FILE ;
# à défaut, une clé secrète age (AGE-SECRET-KEY-...) collée, sans affichage, jamais écrite sur le disque.
#
# Toutes les saisies sont demandées AU DÉBUT (phrase de la clé, mot de passe Samba à choisir, mot de passe du Pi, mot de passe sudo) :
# ensuite le script enchaîne seul. En fin de parcours : rapport de contrôle et, si tu le souhaites, connexion du compte caméra.
set -euo pipefail

HOST="maxime@maxime.local"
REPO_SSH="git@github.com:maximelabatut/maximelabatut-backups.git"
REPO_HTTPS="https://github.com/maximelabatut/maximelabatut-backups.git"
RAW="https://raw.githubusercontent.com/maximelabatut/maximelabatut/main/restore.sh"
HERE="$(cd "$(dirname "$0")" && pwd)"
SSHKEY="${SSH_KEY_FILE:-$HOME/.ssh/id_ed25519_homelab}"

MODE=restore; ARCHIVE=""
for a in "$@"; do
  case "$a" in
    --verifier) MODE=verify ;;
    -h|--help) sed -n 2,16p "$0"; exit 0 ;;
    *) ARCHIVE="$a" ;;
  esac
done

command -v age >/dev/null || { echo "age est requis pour déchiffrer l'archive (cf. docs/ajouter-un-site.md, « Installer age sur le Mac »)."; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/pirestore.XXXXXX")"
chmod 700 "$TMP"
SOCK="$TMP/ssh.sock"
AGENT_PID=""
cleanup() {
  ssh -O exit -o ControlPath="$SOCK" "$HOST" >/dev/null 2>&1 || true
  [ -n "$AGENT_PID" ] && kill "$AGENT_PID" 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT

IDENT="${AGE_KEY_FILE:-}"
[ -z "$IDENT" ] && [ -f "$SSHKEY" ] && IDENT="$SSHKEY"

# ---------------------------------------------------------------------------------------------------------------------
# Clé SSH dans l'agent (une seule saisie de la phrase pour les connexions SSH ; age redemande la sienne pour déchiffrer)
# ---------------------------------------------------------------------------------------------------------------------
load_ssh_key() {
  [ -f "$SSHKEY" ] || return 0
  local rc=0 fp
  ssh-add -l >/dev/null 2>&1 || rc=$?
  if [ "$rc" = 2 ]; then eval "$(ssh-agent -s)" >/dev/null; AGENT_PID="$SSH_AGENT_PID"; fi
  fp="$(ssh-keygen -lf "$SSHKEY.pub" 2>/dev/null | awk '{print $2}')"
  if [ -z "$fp" ] || ! ssh-add -l 2>/dev/null | grep -q "$fp"; then
    echo "Chargement de $SSHKEY dans l'agent SSH (phrase secrète demandée si la clé en a une) :"
    ssh-add "$SSHKEY" 2>&1 | grep -v "^Identity added" || true
  fi
}

# Commande SSH pour GitHub, avec les clés de l'hôte tirées de la liste officielle (api.github.com/meta), à défaut accept-new.
GH_KNOWN="$TMP/gh_known_hosts"
gh_ssh() {  # $1 = fichier de clé
  if [ ! -e "$GH_KNOWN" ]; then
    curl -fsS -m 15 https://api.github.com/meta 2>/dev/null \
      | python3 -c 'import json,sys; [print("github.com", k) for k in json.load(sys.stdin)["ssh_keys"]]' > "$GH_KNOWN" 2>/dev/null || : > "$GH_KNOWN"
  fi
  if [ -s "$GH_KNOWN" ]; then
    echo "ssh -i $1 -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=15 -o UserKnownHostsFile=$GH_KNOWN -o StrictHostKeyChecking=yes"
  else
    echo "ssh -i $1 -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new"
  fi
}

# ---------------------------------------------------------------------------------------------------------------------
# Récupération et déchiffrement de l'archive
# ---------------------------------------------------------------------------------------------------------------------
fetch_archive() {
  [ -n "$ARCHIVE" ] && return 0
  echo "Récupération de la dernière sauvegarde (dépôt de sauvegardes)..."
  if [ -f "$SSHKEY" ] && GIT_SSH_COMMAND="$(gh_ssh "$SSHKEY")" git clone -q --depth 1 "$REPO_SSH" "$TMP/bk" 2>/dev/null; then
    echo "  (clonée avec la clé SSH, sans identifiants GitHub)"
  else
    echo "  Clonage par clé SSH impossible (clé non enregistrée comme Deploy key du dépôt, ou réseau) : essai en HTTPS."
    git clone -q --depth 1 "$REPO_HTTPS" "$TMP/bk" || { echo "Clonage impossible : télécharger l'archive depuis la page GitHub du dépôt et la passer en argument."; exit 1; }
  fi
  NB="$(ls -1 "$TMP"/bk/homelab-*.tar.gz.age 2>/dev/null | wc -l | tr -d ' ' || true)"
  ARCHIVE="$(ls -1 "$TMP"/bk/homelab-*.tar.gz.age 2>/dev/null | sort | tail -1 || true)"
  [ -n "$ARCHIVE" ] || { echo "Aucune archive dans le dépôt de sauvegardes."; exit 1; }
}

decrypt_archive() {
  [ -f "$ARCHIVE" ] || { echo "Archive introuvable : $ARCHIVE"; exit 1; }
  echo "Archive : $(basename "$ARCHIVE")${NB:+ (${NB} disponible(s))}"
  mkdir -m 700 "$TMP/x"
  if [ -n "$IDENT" ]; then
    [ -f "$IDENT" ] || { echo "Clé introuvable : $IDENT"; exit 1; }
    echo "Déchiffrement avec $IDENT (saisir sa phrase secrète si elle est demandée)."
    age -d -i "$IDENT" "$ARCHIVE" | tar xzf - -C "$TMP/x" || { echo "Déchiffrement impossible (mauvaise clé ou phrase secrète ?)."; exit 1; }
  else
    local KEY
    read -r -s -p "Clé secrète age (AGE-SECRET-KEY-...) ou, à défaut, relancer avec AGE_KEY_FILE=chemin de la clé SSH : " KEY; echo
    [[ "$KEY" == AGE-SECRET-KEY-* ]] || { echo "Ce n'est pas une clé secrète age."; exit 1; }
    age -d -i <(printf '%s\n' "$KEY") "$ARCHIVE" | tar xzf - -C "$TMP/x" || { echo "Déchiffrement impossible (mauvaise clé ?)."; exit 1; }
    unset KEY
  fi
  [ -f "$TMP/x/MANIFEST.txt" ] && { echo "--- contenu de la sauvegarde :"; cat "$TMP/x/MANIFEST.txt"; echo "---"; }
  [ -f "$TMP/x/env" ] || { echo "Archive invalide : .env absent."; exit 1; }
}

# ---------------------------------------------------------------------------------------------------------------------
# Contrôles de restaurabilité (utilisés par --verifier ; en restauration, seules les erreurs graves arrêtent le script)
# ---------------------------------------------------------------------------------------------------------------------
OKN=0; WARN=0; ERR=0
ok()   { echo "  ✔ $*"; OKN=$((OKN + 1)); }
warn() { echo "  ⚠ $*"; WARN=$((WARN + 1)); }
bad()  { echo "  ✘ $*"; ERR=$((ERR + 1)); }

check_archive() {
  local X="$TMP/x" d epoch now age_h f tok all exp
  echo "Contrôles de la sauvegarde :"

  # fraîcheur
  d="$(basename "$ARCHIVE" | sed -E 's/^homelab-([0-9]{4}-[0-9]{2}-[0-9]{2}).*/\1/')"
  epoch="$(date -j -f %Y-%m-%d "$d" +%s 2>/dev/null || date -d "$d" +%s 2>/dev/null || echo "")"
  if [ -n "$epoch" ]; then
    now="$(date +%s)"; age_h=$(( (now - epoch) / 3600 ))
    if [ "$age_h" -le 48 ]; then ok "archive du $d (il y a moins de 48 h)"
    elif [ "$age_h" -le 96 ]; then warn "archive du $d : plus de 48 h, la sauvegarde quotidienne a peut-être manqué un passage"
    else bad "archive du $d : plus de 4 jours, la sauvegarde quotidienne semble arrêtée (journalctl -u homelab-backup sur le Pi)"; fi
  else
    warn "date de l'archive illisible ($(basename "$ARCHIVE"))"
  fi
  [ -n "${NB:-}" ] && ok "$NB archive(s) dans le dépôt (30 maximum)"

  # contenu
  for f in env MANIFEST.txt uptime-kuma-data.tgz gamevault-data.tgz gamevault-deploy-key homewatch-deploy-key homelab-backup/recipient homelab-backup/deploy-key; do
    if [ -s "$X/$f" ]; then ok "présent : $f"; else bad "absent ou vide : $f"; fi
  done

  # tokens
  if [ -s "$X/env" ]; then
    tok="$(awk -F= '/^CLOUDFLARE_TUNNEL_TOKEN_/ && length($2) > 100 {n++} END {print n+0}' "$X/env")"
    all="$(grep -c '^CLOUDFLARE_TUNNEL_TOKEN_' "$X/env" || true)"
    exp="$(grep -c '^CLOUDFLARE_TUNNEL_TOKEN_' "$HERE/../.env.example" 2>/dev/null || true)"; exp="${exp:-0}"
    if [ "$tok" -ge 1 ] && [ "$tok" = "$all" ]; then ok "$tok token(s) Cloudflare valides"; else bad "tokens Cloudflare invalides ($tok valides sur $all)"; fi
    if [ "$exp" -gt 0 ] && [ "$tok" != "$exp" ]; then warn "$tok token(s) dans l'archive, $exp attendus d'après .env.example (application ajoutée depuis ?)"; fi
    grep -q '^DOCKER_GID=' "$X/env" || warn "pas de DOCKER_GID (recalculé à la restauration)"
  fi

  # bases de données
  if command -v sqlite3 >/dev/null; then
    if [ -s "$X/uptime-kuma-data.tgz" ]; then
      mkdir "$TMP/k"; tar xzf "$X/uptime-kuma-data.tgz" -C "$TMP/k" 2>/dev/null || true
      if [ -f "$TMP/k/kuma.db" ] && [ "$(sqlite3 "$TMP/k/kuma.db" 'PRAGMA integrity_check;' 2>/dev/null)" = "ok" ]; then
        ok "Uptime Kuma : base saine, $(sqlite3 "$TMP/k/kuma.db" 'SELECT count(*) FROM monitor;') sondes, $(sqlite3 "$TMP/k/kuma.db" 'SELECT count(*) FROM notification;') notification(s)"
      else bad "Uptime Kuma : base illisible ou corrompue"; fi
    fi
    if [ -s "$X/gamevault-data.tgz" ]; then
      mkdir "$TMP/g"; tar xzf "$X/gamevault-data.tgz" -C "$TMP/g" 2>/dev/null || true
      if [ -f "$TMP/g/catalog.db" ] && [ "$(sqlite3 "$TMP/g/catalog.db" 'PRAGMA integrity_check;' 2>/dev/null)" = "ok" ]; then
        ok "GameVault : base saine, $(sqlite3 "$TMP/g/catalog.db" 'SELECT count(*) FROM games;') jeux"
      else bad "GameVault : base illisible ou corrompue"; fi
    fi
  else
    warn "sqlite3 absent du poste : intégrité des bases non contrôlée"
  fi

  # les clés de déploiement joignent-elles leurs dépôts ? (lecture seule, aucune écriture)
  local k net
  if [ "$MODE" = verify ]; then net=bad; else net=warn; fi
  for k in gamevault homewatch; do
    if [ -s "$X/$k-deploy-key" ]; then
      chmod 600 "$X/$k-deploy-key"
      if GIT_SSH_COMMAND="$(gh_ssh "$X/$k-deploy-key")" git ls-remote "git@github.com:maximelabatut/$k.git" HEAD >/dev/null 2>&1; then
        ok "clé de déploiement $k : dépôt joignable"
      else $net "clé de déploiement $k : dépôt injoignable (clé retirée des Deploy keys du dépôt, ou GitHub injoignable)"; fi
    fi
  done
  if [ -s "$X/homelab-backup/deploy-key" ]; then
    chmod 600 "$X/homelab-backup/deploy-key"
    if GIT_SSH_COMMAND="$(gh_ssh "$X/homelab-backup/deploy-key")" git ls-remote "$REPO_SSH" HEAD >/dev/null 2>&1; then
      ok "clé d'écriture des sauvegardes : dépôt joignable"
    else $net "clé d'écriture des sauvegardes : dépôt injoignable (la sauvegarde quotidienne échouerait)"; fi
  fi

  # la clé que tu détiens est-elle celle qui chiffre les prochaines sauvegardes ?
  if [ -f "$SSHKEY.pub" ] && [ -s "$X/homelab-backup/recipient" ]; then
    if [ "$(awk '{print $1" "$2}' "$SSHKEY.pub")" = "$(head -1 "$X/homelab-backup/recipient")" ]; then
      ok "la clé $(basename "$SSHKEY") est bien celle qui chiffre les sauvegardes"
    else
      warn "les sauvegardes sont chiffrées pour une AUTRE clé que $(basename "$SSHKEY") : sans l'autre clé, elles seraient illisibles"
    fi
  fi

  echo "Bilan : $OKN contrôle(s) réussi(s), $WARN avertissement(s), $ERR erreur(s)."
}

# ---------------------------------------------------------------------------------------------------------------------
# Mode test à blanc
# ---------------------------------------------------------------------------------------------------------------------
if [ "$MODE" = verify ]; then
  load_ssh_key
  fetch_archive
  decrypt_archive
  check_archive
  if [ "$ERR" -gt 0 ]; then echo "La restauration serait compromise : corriger les erreurs ci-dessus."; exit 1; fi
  [ "$WARN" -gt 0 ] && echo "Restaurable, avec des points d'attention." || echo "Restauration possible : tout est conforme."
  exit 0
fi

# ---------------------------------------------------------------------------------------------------------------------
# Mode restauration
# ---------------------------------------------------------------------------------------------------------------------
load_ssh_key
fetch_archive
decrypt_archive
check_archive
if [ "$ERR" -gt 0 ] && [ "${FORCE:-0}" != 1 ]; then
  read -r -p "Des erreurs ont été détectées dans la sauvegarde. Continuer malgré tout ? [o/N] " A
  [ "${A:-n}" = o ] || [ "${A:-n}" = O ] || { echo "Abandon (essayer une archive plus ancienne : restaurer-pi.sh chemin/archive.age)."; exit 1; }
fi

# Mot de passe Samba : choisi maintenant, envoyé par fichier temporaire (600), jamais stocké.
while true; do
  read -r -s -p "Choisis le mot de passe Samba de maxime : " S1; echo
  read -r -s -p "Confirme-le : " S2; echo
  [ -n "$S1" ] && [ "$S1" = "$S2" ] && break
  echo "   Les mots de passe sont vides ou différents, recommence."
done
( umask 077; printf '%s\n' "$S1" > "$TMP/smb" )
unset S1 S2

if curl -fsSL "$RAW" -o "$TMP/restore.sh"; then echo "restore.sh récupéré depuis GitHub."; else echo "restore.sh introuvable sur GitHub."; exit 1; fi

# La clé SSH du Pi change à chaque reflash.
ssh-keygen -R maxime.local >/dev/null 2>&1 || true
OPTS=(-o StrictHostKeyChecking=accept-new -o ControlMaster=auto -o ControlPath="$SOCK" -o ControlPersist=30m)

echo "Connexion au Pi (saisis le mot de passe de l'utilisateur maxime, une seule fois)..."
ssh "${OPTS[@]}" "$HOST" true

X="$TMP/x"
scp -q "${OPTS[@]}" "$X/env" "$HOST:/tmp/pi.env"
scp -q "${OPTS[@]}" "$TMP/smb" "$HOST:/tmp/pi.smb"
for f in uptime-kuma-data.tgz gamevault-data.tgz; do
  if [ -f "$X/$f" ]; then scp -q "${OPTS[@]}" "$X/$f" "$HOST:/tmp/$f"; echo "$f envoyé."; else echo "Pas de $f dans l'archive."; fi
done
for k in gamevault homewatch; do
  if [ -f "$X/$k-deploy-key" ]; then scp -q "${OPTS[@]}" "$X/$k-deploy-key" "$HOST:/tmp/$k-deploy-key"; echo "Clé de déploiement $k envoyée."; else echo "Pas de clé de déploiement $k : son code ne sera pas cloné."; fi
done
if [ -d "$X/homelab-backup" ]; then
  tar czf "$TMP/cfg.tgz" -C "$X/homelab-backup" .
  scp -q "${OPTS[@]}" "$TMP/cfg.tgz" "$HOST:/tmp/homelab-backup-config.tgz"
  echo "Configuration de la sauvegarde quotidienne envoyée."
fi
# Clé publique de ton poste : installée dans authorized_keys (les mots de passe restent acceptés jusqu'au durcissement SSH).
HAVE_KEY=0
if [ -f "$SSHKEY.pub" ]; then
  scp -q "${OPTS[@]}" "$SSHKEY.pub" "$HOST:/tmp/pi.authkey"; HAVE_KEY=1
fi
scp -q "${OPTS[@]}" "$TMP/restore.sh" "$HOST:/tmp/restore.sh"

echo
echo "Toutes les saisies sont faites, sauf le mot de passe sudo demandé tout de suite. Le Pi se restaure seul (20 à 30 min)."
ssh -t "${OPTS[@]}" "$HOST" "bash /tmp/restore.sh; rm -f /tmp/restore.sh" || true

# ---------------------------------------------------------------------------------------------------------------------
# Après le redémarrage : attente du Pi, rapport de contrôle, connexion du compte caméra, partage Samba
# ---------------------------------------------------------------------------------------------------------------------
if [ "$HAVE_KEY" != 1 ]; then
  echo "Clé SSH $SSHKEY.pub absente : rapport automatique ignoré. Attendre ~2 min puis suivre docs/restauration-pas-a-pas.md (tâches 15 à 19)."
  exit 0
fi
KOPTS=(-i "$SSHKEY" -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ConnectTimeout=5)
echo
echo "Attente du redémarrage du Pi (5 minutes au maximum)..."
sleep 20
UP=0
for _ in $(seq 1 28); do
  if ssh "${KOPTS[@]}" "$HOST" true >/dev/null 2>&1; then UP=1; break; fi
  sleep 10
done
[ "$UP" = 1 ] || { echo "Le Pi ne répond pas par clé SSH. Vérifier à la main : ssh maxime@maxime.local (docs/restauration-pas-a-pas.md, tâches 14 et suivantes)."; exit 0; }
echo "Le Pi est de retour. Attente du démarrage des conteneurs (60 s)..."
sleep 60

echo
echo "================ RAPPORT ================"
ssh "${KOPTS[@]}" "$HOST" 'bash -s' <<'REMOTE' || true
cd ~/docker
echo "== Conteneurs qui ne tournent pas (homewatch en redémarrage est normal avant la connexion du compte caméra) :"
docker compose ps -a --format '{{.Name}} {{.State}}' | awk '$2 != "running"' | sed 's/^/   /'
echo "   ($(docker compose ps --format '{{.Name}}' | wc -l | tr -d ' ') conteneurs actifs)"
echo "== Température et alimentation"
vcgencmd measure_temp
vcgencmd get_throttled
echo "== Contrôle d'accès (Cloudflare Access)"
bash ~/docker/pi/verifier-acces.sh || true
echo "== Sauvegarde quotidienne"
echo "   timer : $(systemctl is-active homelab-backup.timer)"
systemctl list-timers homelab-backup --no-pager | sed -n 2p | cut -c1-90 | sed 's/^/   /'
REMOTE
echo "========================================="

echo
read -r -p "Connecter le compte caméra (Homewatch) maintenant ? Il faudra l'e-mail, le mot de passe et le code reçu. [O/n] " A
if [ "${A:-O}" != n ] && [ "${A:-O}" != N ]; then
  echo "Quand la liste des caméras s'affiche (« Connecté »), appuie sur Ctrl-C : le script relance ensuite Homewatch."
  ssh -t "${KOPTS[@]}" "$HOST" 'cd ~/docker && docker compose stop homewatch >/dev/null; docker compose run --rm homewatch; docker compose up -d homewatch' || true
  ssh "${KOPTS[@]}" "$HOST" 'sleep 10; cd ~/docker && docker compose logs --tail 5 homewatch' || true
else
  echo "Plus tard : ssh maxime@maxime.local puis cd ~/docker && docker compose run --rm homewatch (Ctrl-C après « Connecté »), puis docker compose up -d homewatch."
fi

command -v open >/dev/null && open "smb://maxime@maxime.local/docker" >/dev/null 2>&1 || true

echo
echo "Restauration terminée. Reste à ta charge :"
echo "  - durcissement SSH (docs/restauration-pas-a-pas.md, tâche 16 : ta clé est déjà installée sur le Pi, il ne reste que le test et le fichier de configuration)"
echo "  - vérifier les sites protégés par Access dans le navigateur (e-mail + code + MFA)"
echo "  - Finder : le partage smb://maxime.local/docker vient de s'ouvrir (mot de passe Samba choisi au début)"
