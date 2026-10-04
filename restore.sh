#!/bin/bash
# Restauration complète du Pi sur une carte SD vierge. Lancé par restaurer-pi.sh (Mac) via ssh -t.
# Prérequis : le .env a été copié sur le Pi dans /tmp/pi.env. Relançable sans risque.
set -euo pipefail

REPO="https://github.com/maximelabatut/maximelabatut.git"
SRC_ENV="/tmp/pi.env"

[ -f "$SRC_ENV" ] || { echo "Fichier $SRC_ENV manquant (il doit être copié depuis le Mac)."; exit 1; }

# sudo demande un mot de passe sur ce Pi et l'oublie au bout de 5 min : on le saisit une fois, puis on le maintient.
echo "== Droits administrateur (mot de passe du Pi)"
sudo -v
( while true; do sudo -n true 2>/dev/null; sleep 50; kill -0 "$$" 2>/dev/null || exit; done ) &
KEEPALIVE=$!
trap 'kill "$KEEPALIVE" 2>/dev/null || true' EXIT

echo "== 1/7 Système"
sudo apt-get update -y
sudo DEBIAN_FRONTEND=noninteractive apt-get full-upgrade -y -o Dpkg::Options::=--force-confold
sudo apt-get install -y locales-all git

echo "== 2/7 Docker"
command -v docker >/dev/null || curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker "$USER"

echo "== 3/7 Dépôt GitHub"
[ -d "$HOME/docker/.git" ] || git clone "$REPO" "$HOME/docker"
mkdir -p "$HOME/docker/www/html/data" "$HOME/docker/dashboard/data" "$HOME/docker/uptime-kuma/data" "$HOME/docker/gamevault/app" "$HOME/docker/gamevault/data" "$HOME/docker/homewatch/app" "$HOME/docker/homewatch/data"
# Clone d'un dépôt privé avec sa clé de déploiement (lecture seule), ou git pull s'il existe déjà.
# Une clé par dépôt (GitHub n'accepte pas la même clé sur deux dépôts) : /tmp/<nom>-deploy-key, alias SSH github-<nom>.
deploy_repo() {
  local name="$1" keyfile="/tmp/$1-deploy-key" app="$HOME/docker/$1/app"
  [ -f "$keyfile" ] || return 0
  echo "   Code $name : clone du dépôt privé (clé de déploiement en lecture seule)"
  mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"
  install -m 600 "$keyfile" "$HOME/.ssh/${name}_deploy"
  rm -f "$keyfile"
  if ! grep -q "^Host github-$name\$" "$HOME/.ssh/config" 2>/dev/null; then
    cat >> "$HOME/.ssh/config" <<SSHCONF
Host github-$name
  HostName github.com
  User git
  IdentityFile $HOME/.ssh/${name}_deploy
  IdentitiesOnly yes
  StrictHostKeyChecking accept-new
SSHCONF
    chmod 600 "$HOME/.ssh/config"
  fi
  if [ -d "$app/.git" ]; then
    git -C "$app" pull --ff-only || echo "   pull impossible, le code existant est conservé"
  else
    rm -rf "$app.tmp"
    if git clone "git@github-$name:maximelabatut/$name.git" "$app.tmp"; then
      rm -rf "$app"; mv "$app.tmp" "$app"
    else
      echo "   Clone impossible (clé non enregistrée dans les Deploy keys du dépôt $name ?)"; rm -rf "$app.tmp"
    fi
  fi
}

deploy_repo gamevault
deploy_repo homewatch

GV_APP="$HOME/docker/gamevault/app"
if [ ! -f "$GV_APP/rss_proxy_server.py" ] && [ -f /tmp/gamevault-app.tgz ]; then
  echo "   Code GameVault : repli sur l'archive envoyée depuis le Mac"
  tar xzf /tmp/gamevault-app.tgz -C "$GV_APP"
fi
rm -f /tmp/gamevault-app.tgz
[ -f "$HOME/docker/homewatch/app/homewatch_server.py" ] || echo "   ATTENTION : le code de Homewatch est absent de ~/docker/homewatch/app (le conteneur homewatch ne se construira pas)."
if [ -f /tmp/gamevault-data.tgz ]; then
  echo "   Restauration de la base GameVault"
  tar xzf /tmp/gamevault-data.tgz -C "$HOME/docker/gamevault/data"
  rm -f /tmp/gamevault-data.tgz
fi
[ -f "$HOME/docker/gamevault/app/rss_proxy_server.py" ] || echo "   ATTENTION : le code de GameVault est absent de ~/docker/gamevault/app (le conteneur gamevault ne démarrera pas)."
if [ -f /tmp/uptime-kuma-data.tgz ]; then
  echo "   Restauration des données Uptime Kuma"
  tar xzf /tmp/uptime-kuma-data.tgz -C "$HOME/docker/uptime-kuma/data"
  rm -f /tmp/uptime-kuma-data.tgz
fi

echo "   Sauvegarde sans mot de passe : script root et règle sudo limitée"
sudo bash "$HOME/docker/pi/install-backup.sh"

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
if [ ! -f "$HOME/docker/homewatch/data/auth_token.json" ]; then
  echo
  echo "Homewatch : première connexion à faire (code de vérification, une seule fois) :"
  echo "  cd ~/docker && docker compose run --rm homewatch"
fi
echo "Terminé. Redémarrage dans 10 s pour activer le ventilateur Argon (les conteneurs repartent seuls)."
sleep 10
sudo reboot
