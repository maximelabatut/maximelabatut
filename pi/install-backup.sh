#!/bin/bash
# À lancer avec sudo, depuis le Pi : sudo bash ~/docker/pi/install-backup.sh
# Installe la sauvegarde quotidienne chiffrée vers le dépôt GitHub privé de sauvegardes (timer systemd).
# Relançable sans risque. Interactif au premier passage (clé publique age + clé d'écriture à enregistrer sur GitHub) ;
# lors d'une restauration, /etc/homelab-backup est déjà rempli depuis la dernière archive : aucune question.
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "À lancer avec sudo : sudo bash $0"; exit 1; }

SRC="$(cd "$(dirname "$0")" && pwd)"
CONF="/etc/homelab-backup"
REPO_WEB="https://github.com/maximelabatut/maximelabatut-backups"

echo "== Paquets"
for p in age sqlite3 git curl python3; do command -v "$p" >/dev/null || NEED="${NEED:-} $p"; done
[ -z "${NEED:-}" ] || { apt-get update -y; apt-get install -y $NEED; }

echo "== Scripts et timer"
install -m 755 -o root -g root "$SRC/homelab-backup" /usr/local/sbin/homelab-backup
install -m 755 -o root -g root "$SRC/verifier-acces.sh" /usr/local/sbin/homelab-check-access
install -m 644 -o root -g root "$SRC/homelab-backup.service" /etc/systemd/system/homelab-backup.service
install -m 644 -o root -g root "$SRC/homelab-backup.timer" /etc/systemd/system/homelab-backup.timer
# Ancien système (sauvegarde tirée depuis le Mac) : plus utile, et ses instantanés en clair n'ont plus de raison d'exister.
rm -f /etc/sudoers.d/homelab-backup
rm -rf /var/backups/homelab

install -d -m 700 -o root -g root "$CONF"
chown -R root:root "$CONF"; chmod 600 "$CONF"/* 2>/dev/null || true

echo "== Clé de GitHub (serveur) : vérification contre la liste officielle"
if [ ! -s "$CONF/known_hosts" ]; then
  python3 - > "$CONF/known_hosts.tmp" <<'PY'
import json, urllib.request
d = json.load(urllib.request.urlopen("https://api.github.com/meta", timeout=20))
for k in d["ssh_keys"]:
    print("github.com", k)
PY
  [ -s "$CONF/known_hosts.tmp" ] || { echo "Impossible d'obtenir les clés officielles de GitHub"; exit 1; }
  mv "$CONF/known_hosts.tmp" "$CONF/known_hosts"; chmod 600 "$CONF/known_hosts"
fi

echo "== Clé publique de chiffrement (age)"
if ! head -1 "$CONF/recipient" 2>/dev/null | grep -qE '^age1[a-z0-9]{50,}$'; then
  RECIP="${RECIPIENT:-}"
  if [ -z "$RECIP" ]; then
    [ -t 0 ] || { echo "Clé publique age absente : relancer au terminal (ou RECIPIENT=age1... sudo -E bash $0)"; exit 1; }
    echo "Colle la clé PUBLIQUE age (ligne « Public key: age1... » affichée par age-keygen sur le Mac)."
    read -r -p "Clé publique : " RECIP
  fi
  [[ "$RECIP" =~ ^age1[a-z0-9]{50,}$ ]] || { echo "Ce n'est pas une clé publique age (elle commence par age1). Ne jamais coller la clé secrète (AGE-SECRET-KEY-...)."; exit 1; }
  printf '%s\n' "$RECIP" > "$CONF/recipient"; chmod 600 "$CONF/recipient"
fi

echo "== Clé d'écriture du dépôt de sauvegardes"
if [ ! -s "$CONF/deploy-key" ]; then
  ssh-keygen -q -t ed25519 -N "" -C "homelab-backup@$(hostname)" -f "$CONF/deploy-key"
  NEWKEY=1
fi
if [ "${NEWKEY:-0}" = 1 ] || [ "${SHOWKEY:-0}" = 1 ]; then
  echo
  echo "Ajoute cette clé PUBLIQUE dans $REPO_WEB/settings/keys (Add deploy key)"
  echo "en cochant « Allow write access » (impossible à corriger après coup) :"
  echo
  cat "$CONF/deploy-key.pub"
  echo
  if [ -t 0 ]; then read -r -p "Appuie sur Entrée quand c'est fait... " _; fi
fi
chmod 600 "$CONF"/deploy-key

systemctl daemon-reload
systemctl enable --now homelab-backup.timer >/dev/null
echo "Timer actif : $(systemctl list-timers homelab-backup.timer --no-pager | sed -n 2p | cut -c1-80)"

if [ -t 0 ] && [ "${NOFIRST:-0}" != 1 ]; then
  read -r -p "Lancer la première sauvegarde maintenant ? [O/n] " A
  if [ "${A:-O}" != n ] && [ "${A:-O}" != N ]; then
    systemctl start homelab-backup.service && echo "Sauvegarde terminée." || echo "Échec : journalctl -u homelab-backup -n 30"
    journalctl -u homelab-backup -n 12 --no-pager -o cat
  fi
fi
echo "Installé. Suivi : journalctl -u homelab-backup -n 30   |   prochaine exécution : systemctl list-timers homelab-backup"
