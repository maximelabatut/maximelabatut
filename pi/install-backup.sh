#!/bin/bash
# À lancer avec sudo, depuis le Pi : sudo bash ~/docker/pi/install-backup.sh
# Installe le script de sauvegarde root et la règle sudo qui l'autorise seul, sans mot de passe et sans argument.
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "À lancer avec sudo : sudo bash $0"; exit 1; }

SRC="$(cd "$(dirname "$0")" && pwd)"
USER_NAME="${SUDO_USER:-maxime}"

command -v sqlite3 >/dev/null || apt-get install -y sqlite3
install -m 755 -o root -g root "$SRC/homelab-backup" /usr/local/sbin/homelab-backup

TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT
printf '# Sauvegarde automatique : ce script seul, sans argument, sans mot de passe.\n%s ALL=(root) NOPASSWD: /usr/local/sbin/homelab-backup ""\n' "$USER_NAME" > "$TMP"
# Une erreur dans un fichier sudoers peut bloquer sudo : on valide AVANT d'installer (set -e arrête ici si invalide).
visudo -cf "$TMP"
install -m 440 -o root -g root "$TMP" /etc/sudoers.d/homelab-backup
visudo -c >/dev/null && echo "sudoers valide"
echo "Installé : /usr/local/sbin/homelab-backup et /etc/sudoers.d/homelab-backup"
