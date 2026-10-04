# Restauration après changement de carte SD

Tout est sur GitHub : le code et la configuration dans `github.com/maximelabatut/maximelabatut` (public), et les secrets (`.env`, bases de données, clés de déploiement) dans **une archive chiffrée par jour** du dépôt privé `github.com/maximelabatut/maximelabatut-backups` (30 jours conservés). Rien à refaire côté Cloudflare : les tunnels, Access et le MFA ne dépendent pas de la carte.

**Ce qu'il faut avoir pour restaurer** (et rien d'autre) :
1. l'accès à ton compte GitHub (pour télécharger l'archive)
2. la **clé secrète age** (`AGE-SECRET-KEY-...`), dans le gestionnaire de mots de passe : sans elle, les archives sont illisibles pour toujours
3. le mot de passe de l'utilisateur `maxime` choisi dans Imager (et un poste avec `bash`, `ssh`, `git` et `age` : `brew install age`)

## Procédure rapide

### 1. Flasher (Mac)

Raspberry Pi Imager → **Raspberry Pi OS Lite (64-bit)** → ⚙️ :
- hostname `maxime`, utilisateur `maxime` + mot de passe
- SSH activé
- WiFi (SSID, mot de passe, pays `FR`)
- fuseau `Europe/Paris`

Insérer la carte, brancher, attendre ~2 min que le Pi soit sur le WiFi.

### 2. Lancer le script (Mac)

Récupérer le script (le dépôt est public, aucun identifiant) puis le lancer :

```bash
git clone https://github.com/maximelabatut/maximelabatut.git ~/homelab-restore
~/homelab-restore/mac/restaurer-pi.sh
```

Il récupère la dernière archive dans le dépôt de sauvegardes (GitHub demande tes identifiants : nom d'utilisateur et un *personal access token*, ou ta session `gh`). **Variante sans identifiants** : télécharger le fichier `homelab-AAAA-MM-JJ.tar.gz.age` depuis la page GitHub du dépôt (compte connecté) et le passer en argument : `~/homelab-restore/mac/restaurer-pi.sh ~/Downloads/homelab-AAAA-MM-JJ.tar.gz.age`.

Il demande **quatre saisies** :
1. la clé secrète age (sans affichage, jamais écrite sur le disque)
2. le mot de passe de l'utilisateur `maxime` du Pi, pour SSH (une seule fois pour toute la session)
3. ce même mot de passe pour `sudo` (une fois : le script maintient ensuite l'autorisation, car `sudo` l'oublierait après 5 minutes pendant les mises à jour)
4. le mot de passe Samba à choisir (saisi deux fois, jamais stocké)

Il déchiffre l'archive, affiche son résumé (date, nombre de tokens, de sondes, de jeux) puis enchaîne tout seul : envoi du `.env`, des données d'Uptime Kuma et de GameVault, des clés de déploiement (clone du code des dépôts privés) et de la configuration de la sauvegarde quotidienne, mise à jour système, Docker, clone GitHub, `DOCKER_GID`, Samba, module Argon avec sa courbe de ventilation, `docker compose up -d`, puis redémarrage du Pi. Compter **20 à 30 minutes** (surtout de l'attente). Il peut être relancé sans risque s'il s'interrompt. La sauvegarde quotidienne repart seule (timer systemd), avec les mêmes clés : rien à reconfigurer.

### 3. Vérifier (Mac, ~2 min après la fin)

- `ssh maxime@maxime.local` puis `docker compose -f ~/docker/docker-compose.yml ps` : tous les conteneurs `Up`
- `https://www.maximelabatut.com`, `https://config.maximelabatut.com` (email + code + MFA)
- `https://gamevault.maximelabatut.com` (derrière Access) : le catalogue de jeux est là, avec la même base qu'avant
- `https://uptime.maximelabatut.com` : le compte, les 3 sondes et la notification ntfy sont déjà là (aucune reconfiguration)
- Finder → `Cmd+K` → `smb://maxime.local/docker`
- `vcgencmd get_throttled` → `throttled=0x0`

### 4. Homewatch : première connexion (carte neuve)

Le jeton de session de Homewatch n'est pas exporté (c'est un accès au compte) : après la restauration, refaire la connexion une fois, au terminal du Pi :
```bash
cd ~/docker && docker compose run --rm homewatch
```
(e-mail, mot de passe, code de vérification ; Ctrl-C après « Connecté », puis `docker compose up -d homewatch`). Détails dans `ajouter-un-site.md`.

### 5. Réappliquer le durcissement SSH (carte neuve)

La carte fraîchement flashée accepte de nouveau les mots de passe. Une fois la restauration terminée, refaire la procédure « Mise en place » de la section « Durcissement SSH » de `docs/ajouter-un-site.md` (étapes 2 à 5 : `ssh-copy-id`, test par clé, `00-hardening.conf`, contrôle).

## Ce qui protège quoi

**Dans l'archive chiffrée** (`homelab-AAAA-MM-JJ.tar.gz.age`, une par jour, 30 conservées, sauvegarde faite par le Pi lui-même) :

| Contenu | Rôle | S'il manque |
|---|---|---|
| `env` | les 8 tokens des tunnels Cloudflare | `restaurer-pi.sh` s'arrête. Les tokens se récupèrent un par un dans Cloudflare |
| `uptime-kuma-data.tgz` | compte administrateur, sondes, notification ntfy | Uptime Kuma redemande l'installation (~10 min à refaire à la main) |
| `gamevault-data.tgz` | la base GameVault (catalogue de jeux, wishlist) | GameVault repart avec une **base vide** : c'est la seule donnée irremplaçable du projet |
| `gamevault-deploy-key`, `homewatch-deploy-key` | clés de déploiement (lecture seule) qui permettent de cloner les dépôts privés | le conteneur correspondant n'a pas de code et ne démarre pas |
| `homelab-backup/` | clé publique age, clé d'écriture du dépôt de sauvegardes, URL Uptime Kuma | la sauvegarde quotidienne doit être reconfigurée (`sudo bash ~/docker/pi/install-backup.sh`) |
| `MANIFEST.txt` | date et résumé, sans secret | rien d'important |

**À garder hors de l'archive (indispensable, à toi de les conserver)** :
- la **clé secrète age** : dans le gestionnaire de mots de passe, avec une copie hors ligne. Perdue, toutes les sauvegardes sont définitivement illisibles ; volée avec l'accès au dépôt, toutes les sauvegardes sont lisibles
- l'accès à ton compte GitHub (avec sa double authentification)
- la clé SSH `~/.ssh/id_ed25519_homelab` et sa phrase secrète (Trousseau d'accès) : pas pour restaurer (une carte neuve accepte le mot de passe), mais pour réappliquer ensuite le durcissement SSH
- le dépôt `maximelabatut` doit rester **public** : `restore.sh` s'y clone sans identifiants
- le mot de passe Samba et le nom du canal ntfy, dans le gestionnaire de mots de passe
- Homewatch : le jeton de session n'est pas sauvegardé (c'est un accès au compte), d'où l'étape 4

**Rien n'est à garder sur le Mac** : il n'est plus dans la boucle. Le Pi sauvegarde lui-même, qu'il soit éteint ou non, et un nouveau poste peut restaurer avec les trois éléments ci-dessus.

## La sauvegarde quotidienne (côté Pi)

`homelab-backup` tourne en root, chaque jour vers 03h30, lancé par un timer systemd (`Persistent=true` : si le Pi était éteint à cette heure, elle part au démarrage suivant). Il prend des instantanés **cohérents** des bases (SQLite `.backup`, qui tient compte du journal WAL : une simple copie de `kuma.db` perdrait les écritures récentes), **vérifie leur intégrité** (et la présence de tokens valides) avant toute chose, fabrique l'archive en mémoire, la **chiffre avec la clé publique age** (le Pi ne peut donc pas la relire), puis l'envoie sur GitHub en réécrivant l'historique (un seul commit, 30 archives : les plus anciennes disparaissent vraiment). Il vérifie ensuite que GitHub a bien reçu le commit, puis lance le contrôle d'exposition (Cloudflare Access).

Suivi :
```bash
journalctl -u homelab-backup -n 30 --no-pager      # dernier passage
systemctl list-timers homelab-backup                # prochain passage
sudo systemctl start homelab-backup                 # forcer une sauvegarde maintenant
```
Alerte : un moniteur Uptime Kuma de type **Push** (intervalle 25 h) prévient par ntfy si aucune sauvegarde n'a réussi (cf. `ajouter-un-site.md`, « Sauvegarde automatique »).

**Tester la restauration sans toucher au Pi** (à refaire de temps en temps) : télécharger la dernière archive depuis GitHub puis, sur le Mac :
```bash
age -d -i <(pbpaste) ~/Downloads/homelab-AAAA-MM-JJ.tar.gz.age | tar tzv      # clé secrète dans le presse-papiers
```
La liste doit montrer `env`, les deux `.tgz`, les clés de déploiement et `MANIFEST.txt`.

| Quoi | Où | Mise à jour |
|---|---|---|
| Configuration | GitHub, à jour | `git status` et `git log origin/main..HEAD --oneline` sur le Pi doivent être vides |
| Données et secrets | archive chiffrée du jour sur GitHub | automatique |
| Clé SSH d'accès au Pi (+ phrase secrète) | `~/.ssh/id_ed25519_homelab`, phrase dans le Trousseau | copie du fichier et de la phrase dans le gestionnaire de mots de passe |

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
Données d'Uptime Kuma (après avoir déchiffré l'archive : `age -d -i <(pbpaste) homelab-AAAA-MM-JJ.tar.gz.age | tar xzf - -C ~/restore-tmp`) : `scp ~/restore-tmp/uptime-kuma-data.tgz maxime@maxime.local:/tmp/` puis, sur le Pi, `tar xzf /tmp/uptime-kuma-data.tgz -C ~/docker/uptime-kuma/data` avant le premier `docker compose up -d`.

(repo privé : d'abord `sudo apt install -y gh && gh auth login`). Sur le Mac :
```bash
scp ~/restore-tmp/env maxime@maxime.local:~/docker/.env
```
Sur le Pi (`DOCKER_GID` change à chaque installation) :
```bash
cd ~/docker
sed -i '/^DOCKER_GID=/d' .env
sed -i -e '$a\' .env
printf 'DOCKER_GID=%s\n' "$(getent group docker | cut -d: -f3)" >> .env
awk -F= 'NF>1 {print $1, length($2)}' .env
```
Contrôle : 8 tokens de 184 caractères et `DOCKER_GID 3`, chacun sur sa ligne. Puis Samba :
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
| `restaurer-pi.sh` : `Déchiffrement impossible` | mauvaise clé secrète age, ou archive incomplète (retélécharger) |
| `restaurer-pi.sh` : `Clonage impossible` | identifiants GitHub refusés : télécharger l'archive depuis la page du dépôt et la passer en argument |
| `ssh: Could not resolve hostname maxime.local` | le Pi n'est pas encore sur le WiFi (attendre, vérifier les identifiants WiFi saisis dans Imager) |
| `REMOTE HOST IDENTIFICATION HAS CHANGED` | `ssh-keygen -R maxime.local` (le script le fait déjà) |
| `Provided Tunnel token is not valid` | `.env` mal formé : relancer le contrôle des longueurs (6 × 184, `DOCKER_GID 3`) |
| Cloudflare `1033` | conteneur `cloudflared-<service>` arrêté : `docker compose logs cloudflared-<service>` |
| Finder refuse la connexion à `smb://maxime.local/docker` après restauration | le mot de passe Samba a changé : supprimer l'entrée `maxime.local` dans Trousseau d'accès, puis refaire `Cmd+K` |
| `403` nginx | dossier appartenant à `root` : `sudo chown -R maxime:maxime ~/docker/<service>` |
| `permission denied` sur Docker | se déconnecter/reconnecter après `usermod -aG docker` |

Détails complets : `ajouter-un-site.md`.
