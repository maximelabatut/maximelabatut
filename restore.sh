#!/bin/bash
# Restauration complète du Pi sur une carte SD vierge. Lancé par restaurer-pi.sh (Mac) via ssh -t.
# Prérequis : le .env a été copié sur le Pi dans /tmp/pi.env. Relançable sans risque.
set -euo pipefail

REPO="https://github.com/maximelabatut/maximelabatut.git"
SRC_ENV="/tmp/pi.env"

[ -f "$SRC_ENV" ] || { echo "Fichier $SRC_ENV manquant (il doit être copié depuis le Mac)."; exit 1; }

echo "== 1/7 Système"
sudo apt-get update -y
sudo DEBIAN_FRONTEND=noninteractive apt-get full-upgrade -y -o Dpkg::Options::=--force-confold
sudo apt-get install -y locales-all git

echo "== 2/7 Docker"
command -v docker >/dev/null || curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker "$USER"

echo "== 3/7 Dépôt GitHub"
[ -d "$HOME/docker/.git" ] || git clone "$REPO" "$HOME/docker"
mkdir -p "$HOME/docker/www/html/data" "$HOME/docker/dashboard/data"

echo "== 4/7 Secrets (.env)"
cp "$SRC_ENV" "$HOME/docker/.env"
sed -i '/^DOCKER_GID=/d' "$HOME/docker/.env"
sed -i -e '$a\' "$HOME/docker/.env"
printf 'DOCKER_GID=%s\n' "$(getent group docker | cut -d: -f3)" >> "$HOME/docker/.env"
chmod 600 "$HOME/docker/.env"
rm -f "$SRC_ENV"
awk -F= 'NF>1 {print "   " $1, length($2)}' "$HOME/docker/.env"

echo "== 5/7 Samba"
sudo apt-get install -y samba samba-common-bin
if ! grep -q '^\[docker\]' /etc/samba/smb.conf; then
  sudo tee -a /etc/samba/smb.conf > /dev/null <<EOF

[docker]
   path = $HOME/docker
   browseable = yes
   writable = yes
   guest ok = no
   valid users = $USER
   create mask = 0664
   directory mask = 0775
EOF
fi
sudo systemctl enable --now smbd
while true; do
  read -r -s -p "Choisis le mot de passe Samba de $USER : " P1; echo
  read -r -s -p "Confirme-le : " P2; echo
  [ -n "$P1" ] && [ "$P1" = "$P2" ] && break
  echo "   Les mots de passe sont vides ou différents, recommence."
done
printf '%s\n%s\n' "$P1" "$P1" | sudo smbpasswd -s -a "$USER"
unset P1 P2

echo "== 6/7 Boîtier Argon ONE V2"
curl -fsSL https://download.argon40.com/argon1.sh | bash
sudo cp "$HOME/docker/argon/argononed.conf" /etc/argononed.conf

echo "== 7/7 Conteneurs"
cd "$HOME/docker"
sg docker -c "docker compose up -d"
sg docker -c "docker compose ps"

echo
echo "Terminé. Redémarrage dans 10 s pour activer le ventilateur Argon (les conteneurs repartent seuls)."
sleep 10
sudo reboot
