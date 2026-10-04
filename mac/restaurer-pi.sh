#!/bin/bash
# À lancer depuis un Mac (ou tout poste avec bash, ssh et age), une fois la carte SD flashée (Raspberry Pi Imager) et le Pi démarré.
#   restaurer-pi.sh [archive.tar.gz.age]
# Sans argument, la dernière archive est récupérée dans le dépôt privé de sauvegardes (identifiants GitHub demandés si besoin).
# Sinon : télécharger l'archive depuis la page GitHub du dépôt (compte connecté) et passer son chemin en argument.
# Déchiffrement avec la clé SSH ~/.ssh/id_ed25519_homelab (age demande sa phrase secrète au terminal), ou toute autre
# clé indiquée par AGE_KEY_FILE (clé SSH ed25519 ou fichier de clé age). À défaut, une clé secrète age (AGE-SECRET-KEY-...)
# peut être collée : elle est demandée sans affichage et jamais écrite sur le disque.
# Un seul mot de passe SSH à saisir (celui du Pi), plus le futur mot de passe Samba.
set -euo pipefail

HOST="maxime@maxime.local"
BACKUP_REPO="https://github.com/maximelabatut/maximelabatut-backups.git"
RAW="https://raw.githubusercontent.com/maximelabatut/maximelabatut/main/restore.sh"

command -v age >/dev/null || { echo "age est requis pour déchiffrer l'archive : brew install age (ou apt install age)."; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/pirestore.XXXXXX")"
SOCK="$TMP/ssh.sock"
trap 'ssh -O exit -o ControlPath="$SOCK" "$HOST" >/dev/null 2>&1 || true; rm -rf "$TMP"' EXIT
chmod 700 "$TMP"

ARCHIVE="${1:-}"
if [ -z "$ARCHIVE" ]; then
  echo "Récupération de la dernière sauvegarde dans $BACKUP_REPO ..."
  git clone -q --depth 1 "$BACKUP_REPO" "$TMP/bk" || { echo "Clonage impossible : télécharger l'archive depuis GitHub et relancer avec son chemin."; exit 1; }
  ARCHIVE="$(ls -1 "$TMP"/bk/homelab-*.tar.gz.age 2>/dev/null | sort | tail -1)"
  [ -n "$ARCHIVE" ] || { echo "Aucune archive dans le dépôt de sauvegardes."; exit 1; }
fi
[ -f "$ARCHIVE" ] || { echo "Archive introuvable : $ARCHIVE"; exit 1; }
echo "Archive : $(basename "$ARCHIVE")"

IDENT="${AGE_KEY_FILE:-}"
[ -z "$IDENT" ] && [ -f "$HOME/.ssh/id_ed25519_homelab" ] && IDENT="$HOME/.ssh/id_ed25519_homelab"
mkdir -m 700 "$TMP/x"
if [ -n "$IDENT" ]; then
  [ -f "$IDENT" ] || { echo "Clé introuvable : $IDENT"; exit 1; }
  echo "Déchiffrement avec $IDENT (saisir sa phrase secrète si elle est demandée)."
  age -d -i "$IDENT" "$ARCHIVE" | tar xzf - -C "$TMP/x" || { echo "Déchiffrement impossible (mauvaise clé ou phrase secrète ?)."; exit 1; }
else
  read -r -s -p "Clé secrète age (AGE-SECRET-KEY-...) ou, à défaut, relancer avec AGE_KEY_FILE=chemin de la clé SSH : " KEY; echo
  [[ "$KEY" == AGE-SECRET-KEY-* ]] || { echo "Ce n'est pas une clé secrète age."; exit 1; }
  age -d -i <(printf '%s\n' "$KEY") "$ARCHIVE" | tar xzf - -C "$TMP/x" || { echo "Déchiffrement impossible (mauvaise clé ?)."; exit 1; }
  unset KEY
fi
echo "--- contenu de la sauvegarde :"; cat "$TMP/x/MANIFEST.txt"; echo "---"
[ -f "$TMP/x/env" ] || { echo "Archive invalide : .env absent."; exit 1; }

if curl -fsSL "$RAW" -o "$TMP/restore.sh"; then
  echo "restore.sh récupéré depuis GitHub."
else
  echo "restore.sh introuvable sur GitHub."; exit 1
fi

# La clé SSH du Pi change à chaque reflash.
ssh-keygen -R maxime.local >/dev/null 2>&1 || true

OPTS=(-o StrictHostKeyChecking=accept-new -o ControlMaster=auto -o ControlPath="$SOCK" -o ControlPersist=30m)

echo "Connexion au Pi (saisis le mot de passe de l'utilisateur maxime, une seule fois)..."
ssh "${OPTS[@]}" "$HOST" true

scp -q "${OPTS[@]}" "$TMP/x/env" "$HOST:/tmp/pi.env"
for f in uptime-kuma-data.tgz gamevault-data.tgz; do
  if [ -f "$TMP/x/$f" ]; then scp -q "${OPTS[@]}" "$TMP/x/$f" "$HOST:/tmp/$f"; echo "$f envoyé."; else echo "Pas de $f dans l'archive."; fi
done
for k in gamevault homewatch; do
  if [ -f "$TMP/x/$k-deploy-key" ]; then scp -q "${OPTS[@]}" "$TMP/x/$k-deploy-key" "$HOST:/tmp/$k-deploy-key"; echo "Clé de déploiement $k envoyée."; else echo "Pas de clé de déploiement $k : son code ne sera pas cloné."; fi
done
if [ -d "$TMP/x/homelab-backup" ]; then
  tar czf "$TMP/cfg.tgz" -C "$TMP/x/homelab-backup" .
  scp -q "${OPTS[@]}" "$TMP/cfg.tgz" "$HOST:/tmp/homelab-backup-config.tgz"
  echo "Configuration de la sauvegarde quotidienne envoyée."
fi
scp -q "${OPTS[@]}" "$TMP/restore.sh" "$HOST:/tmp/restore.sh"
ssh -t "${OPTS[@]}" "$HOST" "bash /tmp/restore.sh; rm -f /tmp/restore.sh"

echo
echo "Le Pi redémarre. Dans ~2 minutes : https://www.maximelabatut.com et https://config.maximelabatut.com"
