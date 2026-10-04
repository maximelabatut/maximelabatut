# Restauration après changement de carte SD

Tout est sur GitHub (`github.com/maximelabatut/maximelabatut`) sauf le fichier `.env` (tokens Cloudflare), conservé sur le Mac dans `~/Desktop/raspberrypi/.env`. Rien à refaire côté Cloudflare : les tunnels, Access et le MFA ne dépendent pas de la carte.

## Procédure rapide

### 1. Flasher (Mac)

Raspberry Pi Imager → **Raspberry Pi OS Lite (64-bit)** → ⚙️ :
- hostname `maxime`, utilisateur `maxime` + mot de passe
- SSH activé
- WiFi (SSID, mot de passe, pays `FR`)
- fuseau `Europe/Paris`

Insérer la carte, brancher, attendre ~2 min que le Pi soit sur le WiFi.

### 2. Lancer le script (Mac)

```bash
~/Desktop/raspberrypi/restaurer-pi.sh
```

Il demande **trois saisies** :
1. le mot de passe de l'utilisateur `maxime` du Pi, pour SSH (une seule fois pour toute la session)
2. ce même mot de passe pour `sudo` (une fois : le script maintient ensuite l'autorisation, car `sudo` l'oublierait après 5 minutes pendant les mises à jour)
3. le mot de passe Samba à choisir (saisi deux fois, jamais stocké)

Il enchaîne tout seul : envoi du `.env`, des données d'Uptime Kuma, de la clé de déploiement (clone du code de GameVault depuis le dépôt privé) et de la base de GameVault, mise à jour système, Docker, clone GitHub, `DOCKER_GID`, Samba, module Argon avec sa courbe de ventilation, `docker compose up -d`, puis redémarrage du Pi. Compter **20 à 30 minutes** (surtout de l'attente). Il peut être relancé sans risque s'il s'interrompt.

### 3. Vérifier (Mac, ~2 min après la fin)

- `ssh maxime@maxime.local` puis `docker compose -f ~/docker/docker-compose.yml ps` : tous les conteneurs `Up`
- `https://www.maximelabatut.com`, `https://config.maximelabatut.com` (email + code + MFA)
- `https://gamevault.maximelabatut.com` (derrière Access) : le catalogue de jeux est là, avec la même base qu'avant
- `https://uptime.maximelabatut.com` : le compte, les 3 sondes et la notification ntfy sont déjà là (aucune reconfiguration)
- Finder → `Cmd+K` → `smb://maxime.local/docker`
- `vcgencmd get_throttled` → `throttled=0x0`

## Prérequis à garder en état

| Quoi | Où | Mise à jour |
|---|---|---|
| `.env` (7 tokens) | `~/Desktop/raspberrypi/.env` | `~/Desktop/raspberrypi/sauvegarder-pi.sh` (après tout changement de token) |
| Données d'Uptime Kuma (compte, canal ntfy, sondes) | `~/Desktop/raspberrypi/uptime-kuma-data.tgz` | `~/Desktop/raspberrypi/sauvegarder-pi.sh` (après un changement de sondes ou de notification) |
| Base de GameVault (catalogue, wishlist) | `~/Desktop/raspberrypi/gamevault-data.tgz` | `~/Desktop/raspberrypi/sauvegarder-pi.sh` (périodiquement : la base évolue à chaque utilisation) |
| Clé de déploiement de GameVault (lecture seule) | `~/Desktop/raspberrypi/gamevault-deploy-key` (+ `.pub`, enregistrée dans les Deploy keys du dépôt privé) | une seule fois ; le code est cloné depuis `github.com/maximelabatut/gamevault` à la restauration |
| Code de GameVault (repli) | dossier `~/Desktop/raspberrypi/GameVault/` | utilisé seulement si la clé est absente ou si le clone échoue |
| `sauvegarder-pi.sh` | `~/Desktop/raspberrypi/` (copie du repo : `mac/sauvegarder-pi.sh`) | si modifié dans le repo |
| `restaurer-pi.sh` | `~/Desktop/raspberrypi/` (copie du repo : `mac/restaurer-pi.sh`) | si modifié dans le repo |
| `restore.sh` | repo GitHub (le script Mac le télécharge) ; copie locale en secours dans `~/Desktop/raspberrypi/` | si modifié dans le repo |
| Configuration | GitHub, à jour | `git status` et `git log origin/main..HEAD --oneline` sur le Pi doivent être vides |

`sauvegarder-pi.sh` (Pi allumé ; mot de passe du Pi pour SSH puis pour `sudo`) copie le `.env` et des instantanés **cohérents** des bases d'Uptime Kuma et de GameVault (SQLite `.backup`, qui tient compte du journal WAL : une simple copie de `kuma.db` perdrait les écritures récentes), vérifie son intégrité, et conserve la version précédente en `.prev`. Ces fichiers contiennent des secrets (tokens, hash du compte, canal ntfy) : droits `600`, ne jamais les versionner. Garder aussi le mot de passe Samba et le nom du canal ntfy dans le gestionnaire de mots de passe.

## Procédure manuelle (si le script ne passe pas)

Les mêmes étapes, à la main, sur le Pi (`ssh-keygen -R maxime.local` d'abord sur le Mac, la clé SSH du Pi a changé) :

```bash
sudo apt update && sudo apt full-upgrade -y
sudo apt install -y locales-all git
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker $USER
exit
```
Se reconnecter (`ssh maxime@maxime.local`), puis :
```bash
git clone https://github.com/maximelabatut/maximelabatut.git ~/docker
mkdir -p ~/docker/www/html/data ~/docker/dashboard/data ~/docker/uptime-kuma/data
```
Données d'Uptime Kuma (si `uptime-kuma-data.tgz` existe sur le Mac) : `scp ~/Desktop/raspberrypi/uptime-kuma-data.tgz maxime@maxime.local:/tmp/` puis, sur le Pi, `tar xzf /tmp/uptime-kuma-data.tgz -C ~/docker/uptime-kuma/data` avant le premier `docker compose up -d`.

(repo privé : d'abord `sudo apt install -y gh && gh auth login`). Sur le Mac :
```bash
scp ~/Desktop/raspberrypi/.env maxime@maxime.local:~/docker/.env
```
Sur le Pi (`DOCKER_GID` change à chaque installation) :
```bash
cd ~/docker
sed -i '/^DOCKER_GID=/d' .env
sed -i -e '$a\' .env
printf 'DOCKER_GID=%s\n' "$(getent group docker | cut -d: -f3)" >> .env
awk -F= 'NF>1 {print $1, length($2)}' .env
```
Contrôle : 7 tokens de 184 caractères et `DOCKER_GID 3`, chacun sur sa ligne. Puis Samba :
```bash
sudo apt install -y samba samba-common-bin
sudo tee -a /etc/samba/smb.conf > /dev/null <<'EOF'

[docker]
   path = /home/maxime/docker
   browseable = yes
   writable = yes
   guest ok = no
   valid users = maxime
   create mask = 0664
   directory mask = 0775
EOF
sudo systemctl enable --now smbd
sudo smbpasswd -a maxime
```
Module Argon, puis lancement :
```bash
curl https://download.argon40.com/argon1.sh | bash
sudo cp ~/docker/argon/argononed.conf /etc/argononed.conf
cd ~/docker && docker compose up -d
sudo reboot
```

## Si ça coince

| Symptôme | Cause / correction |
|---|---|
| `restaurer-pi.sh` : `Fichier introuvable : .../.env` | le `.env` n'est pas dans `~/Desktop/raspberrypi/` |
| `ssh: Could not resolve hostname maxime.local` | le Pi n'est pas encore sur le WiFi (attendre, vérifier les identifiants WiFi saisis dans Imager) |
| `REMOTE HOST IDENTIFICATION HAS CHANGED` | `ssh-keygen -R maxime.local` (le script le fait déjà) |
| `Provided Tunnel token is not valid` | `.env` mal formé : relancer le contrôle des longueurs (6 × 184, `DOCKER_GID 3`) |
| Cloudflare `1033` | conteneur `cloudflared-<service>` arrêté : `docker compose logs cloudflared-<service>` |
| Finder refuse la connexion à `smb://maxime.local/docker` après restauration | le mot de passe Samba a changé : supprimer l'entrée `maxime.local` dans Trousseau d'accès, puis refaire `Cmd+K` |
| `403` nginx | dossier appartenant à `root` : `sudo chown -R maxime:maxime ~/docker/<service>` |
| `permission denied` sur Docker | se déconnecter/reconnecter après `usermod -aG docker` |

Détails complets : `ajouter-un-site.md`.
