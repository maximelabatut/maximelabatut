# Ajouter un nouveau site/service — procédure complète

Runbook pour exposer un nouveau service Docker sur `*.maximelabatut.com` via Cloudflare Tunnel, avec accès fichiers en Samba.

Architecture de référence : chaque service = un conteneur web (port dédié sur le Pi) + un tunnel Cloudflare dédié + un sous-domaine public.

Toute la configuration (`docker-compose.yml`, contenu des sites) est versionnée sur [github.com/maximelabatut/maximelabatut](https://github.com/maximelabatut/maximelabatut). Seul `.env` (tokens Cloudflare) n'y est jamais poussé.

---

## Restauration après changement de carte SD

La procédure complète (rapide et manuelle) est dans **`restauration-carte-sd.md`** : après avoir flashé la carte avec Raspberry Pi Imager, une seule commande depuis le Mac (`mac/restaurer-pi.sh`) déchiffre la dernière sauvegarde (archive chiffrée sur GitHub), envoie le `.env` et les données, et lance `restore.sh` (versionné dans le repo) sur le Pi. Ce script réinstalle le système, Docker, clone le repo, recalcule `DOCKER_GID`, configure Samba et le module Argon, puis lance les conteneurs.

Rappels propres au projet (détails dans cette doc) :
- Les tunnels Cloudflare, Access et le MFA ne dépendent pas de la carte : rien à refaire côté Cloudflare.
- Il faut un token par tunnel dans `.env` : `WWW`, `GAMEVAULT`, `WEB2`, `CONFIG`, `LOGS`, `NETDATA`, `UPTIME`, `HOMEWATCH`. `DOCKER_GID` est recalculé à chaque installation (jamais restauré), sur sa propre ligne : si la dernière ligne du fichier n'a pas de retour à la ligne final, la valeur se colle au token précédent et le corrompt (`Provided Tunnel token is not valid`).
- Les dossiers `www/html/data` et `dashboard/data` (remplis par `www-status` et `dashboard-sync`, non versionnés) sont recréés par `mkdir -p` avant le premier lancement, pour qu'ils appartiennent à `maxime`.
- Le mot de passe Samba est redéfini à la restauration (`smbpasswd`) ; s'il change, supprimer l'ancienne entrée `maxime.local` du Trousseau d'accès du Mac avant de se reconnecter au partage.

---

## Module du boîtier Argon ONE V2

Pilote du ventilateur et du bouton d'alimentation du boîtier Argon ONE Pi 4 (V2), à installer sur un Pi fraîchement restauré :

```bash
curl https://download.argon40.com/argon1.sh | bash
```

L'installation crée la commande `argonone-config`. Un redémarrage (`sudo reboot`) peut être nécessaire pour activer le ventilateur et le bouton.

**Sans menu** : la courbe est versionnée dans `argon/argononed.conf` (même format que `/etc/argononed.conf`, service `argononed`). Après l'installation du module et le clone du repo :
```bash
sudo cp ~/docker/argon/argononed.conf /etc/argononed.conf
sudo systemctl restart argononed
```
(c'est ce que fait `restauration-carte-sd.md`, suivi d'un redémarrage). Pour changer la courbe : modifier ce fichier dans le repo (et le `/etc/argononed.conf` du Pi), ou passer par le menu `argonone-config` puis reporter le résultat dans le repo.

Réglage manuel du ventilateur, avec `argonone-config` → `1` (Configure Fan) → `2` (Adjust to temperatures), puis les vitesses utilisées ici :

| Température | Vitesse du ventilateur |
|---|---|
| 55 °C | 30 % |
| 60 °C | 55 % |
| 65 °C | 100 % |

Pour tester le ventilateur : `argonone-config` → `1` → `1` (Always on), vérifier qu'il tourne, puis **remettre le mode 2** (courbe par température). Cette courbe est celle qu'utilise le dashboard pour estimer la vitesse du ventilateur (la vitesse réelle n'est pas exposée par le Pi) : si elle change, mettre à jour la fonction `fanEstimate` de `dashboard/html/index.html`.

⚠️ Ce script est exécuté directement depuis Internet (`curl | bash`) : il vient du fabricant du boîtier (Argon40), à ne relancer que depuis cette URL officielle.

---

## Redémarrer le Raspberry Pi

**Rien à faire** : Docker et Samba sont activés au démarrage (`sudo systemctl enable docker smbd`), et tous les conteneurs du `docker-compose.yml` sont en `restart: unless-stopped` — ils redémarrent donc tout seuls avec Docker, tunnels compris. Comportement validé par un reboot réel : tous les conteneurs repartent automatiquement (sites + tunnels) sans aucune intervention manuelle.

Si une carte SD fraîchement restaurée (cf procédure ci-dessus) ne redémarre pas tout automatiquement, vérifie que ces deux services sont bien activés :
```bash
systemctl is-enabled docker smbd
```
Si l'un des deux ne répond pas `enabled` :
```bash
sudo systemctl enable docker
sudo systemctl enable smbd
```

```bash
sudo reboot
```

Attends ~1-2 minutes, reconnecte-toi :
```bash
ssh maxime@maxime.local
```

### Vérifier que tout est bien reparti

```bash
cd ~/docker
docker compose ps
```
Tous les conteneurs doivent être `Up`. Si l'un d'eux manque ou est `Exited`, relance simplement :
```bash
docker compose up -d
```
(commande idempotente — elle ne touche que ce qui n'est pas déjà dans l'état voulu)

Puis reteste les sites (`https://www.maximelabatut.com`, etc.) et le partage Samba (`smb://maxime.local/docker`).

### Si Docker ne redémarre pas tout seul

Vérifie qu'il est bien activé au boot :
```bash
systemctl is-enabled docker
```
Si la réponse n'est pas `enabled` :
```bash
sudo systemctl enable docker
```

⚠️ **Point de vigilance** : `restart: unless-stopped` ne relance pas un conteneur que tu avais **arrêté manuellement** (`docker compose stop <service>`) juste avant le reboot — c'est le comportement voulu de cette politique (elle respecte un arrêt volontaire). Si un service manque après reboot alors qu'il tournait avant, vérifie que tu ne l'avais pas toi-même arrêté au préalable, sinon relance-le avec `docker compose up -d <service>`.

---

## Durcissement SSH (connexion par clé uniquement)

**État (4 oct. 2026)** : le Pi n'accepte plus que la connexion par **clé SSH** (ed25519) ; les mots de passe et la connexion `root` sont désactivés. SSH n'est atteignable que depuis le réseau local (aucun port ouvert sur la box), donc le gain porte sur les appareils du réseau et la réutilisation de mots de passe ; Fail2ban devient inutile (aucun mot de passe à deviner).

| Où | Quoi |
|---|---|
| Mac | clé `~/.ssh/id_ed25519_homelab`, protégée par une **phrase secrète aléatoire** générée avec l'Assistant mot de passe du Trousseau d'accès et mémorisée par `ssh-add --apple-use-keychain` |
| Mac | bloc `Host maxime.local` dans `~/.ssh/config` (`User maxime`, `IdentityFile`, `IdentitiesOnly yes`, `AddKeysToAgent yes`, `UseKeychain yes`) ; ancien fichier en `config.avant-homelab` |
| Pi | clé publique dans `~/.ssh/authorized_keys` ; réglages dans `/etc/ssh/sshd_config.d/00-hardening.conf` |

Contenu de `00-hardening.conf` :
```
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
PubkeyAuthentication yes
AuthenticationMethods publickey
MaxAuthTries 3
LoginGraceTime 30
```
Le préfixe `00-` est voulu : dans `sshd_config.d`, le **premier** réglage rencontré l'emporte, et un fichier de `cloud-init` peut remettre les mots de passe (`50-cloud-init.conf`).

### Mise en place (sans risque de se verrouiller dehors)

1. Mac : créer la clé (`ssh-keygen -t ed25519 -a 100 -C "mac-maxime-homelab" -f ~/.ssh/id_ed25519_homelab`), phrase secrète collée depuis le Trousseau, puis `ssh-add --apple-use-keychain ~/.ssh/id_ed25519_homelab`.
2. Ajouter le bloc `Host maxime.local` à `~/.ssh/config`, puis `ssh-copy-id -i ~/.ssh/id_ed25519_homelab.pub maxime@maxime.local` (dernier mot de passe saisi).
3. **Avant** de couper les mots de passe, vérifier que la clé seule suffit : `ssh -o PreferredAuthentications=publickey -o PasswordAuthentication=no maxime@maxime.local 'echo clé OK'`.
4. Ouvrir une session sur le Pi et **la laisser ouverte** (porte de secours), y écrire `00-hardening.conf`, valider avec `sudo sshd -t`, relire la configuration **effective** avec `sudo sshd -T | grep -iE '^(passwordauthentication|permitrootlogin|pubkeyauthentication|authenticationmethods)'`, puis `sudo systemctl reload ssh` (reload, pas restart).
5. Dans un **nouveau** terminal : la connexion par clé doit réussir et `ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no maxime@maxime.local` doit répondre `Permission denied (publickey)`.

**Annuler** (depuis la session restée ouverte) : `sudo rm /etc/ssh/sshd_config.d/00-hardening.conf && sudo systemctl reload ssh`.

### Perte de la clé et restauration

- La clé devient le **seul** moyen d'entrer en SSH. En cas de perte du Mac ou de son trousseau : reflasher la carte et lancer `restaurer-pi.sh` depuis n'importe quel poste (les données reviennent de la dernière archive chiffrée sur GitHub). Pour l'éviter, garder une copie de `~/.ssh/id_ed25519_homelab` et de sa phrase secrète dans le gestionnaire de mots de passe.
- Une **carte fraîchement flashée** a de nouveau l'authentification par mot de passe : `restaurer-pi.sh` s'y connecte avec le mot de passe (la clé est refusée, SSH retombe sur le mot de passe) ; ensuite **refaire les étapes 2 à 5** ci-dessus pour réappliquer le durcissement (`ssh-keygen -R maxime.local` est déjà fait par le script).
- La sauvegarde n'utilise plus SSH depuis le Mac : c'est le Pi qui la lance et l'envoie lui-même sur GitHub (cf. « Sauvegarde automatique »).

---

## Monitoring : dashboard, Netdata, Dozzle et Uptime Kuma

Quatre services complémentaires, tous derrière Cloudflare Access (cf section suivante) :

| URL | Service | Rôle | Port local |
|---|---|---|---|
| `config.maximelabatut.com` | Dashboard sur mesure (nginx + page HTML) | Vue d'ensemble : température CPU + courbe, CPU, RAM, stockage, et un tiroir par application (conteneur + tunnel, état, CPU, lien vers les logs) | 8083 |
| `netdata.maximelabatut.com` | Netdata | Métriques détaillées avec historique (capteurs, réseau, disque, alertes) | 19999 (réseau `host`) |
| `logs.maximelabatut.com` | Dozzle | Logs en direct de tous les conteneurs (lecture seule) | 8084 (lié à `127.0.0.1` uniquement) |
| `uptime.maximelabatut.com` | Uptime Kuma | Surveillance des sites toutes les minutes, alertes sur le téléphone via ntfy (cf section « Alertes ») | 8085 (lié à `127.0.0.1` uniquement) |

### Comment ça marche

- **Netdata** tourne en `network_mode: host` avec `pid: host` et les montages `/proc`, `/sys` et le socket Docker (lecture seule). Il lit le groupe `docker` grâce à la variable `DOCKER_GID` du `.env`.
- **Dashboard** : `dashboard/html/index.html` (HTML + JavaScript, sans dépendance externe) interroge l'API de Netdata. Le conteneur nginx (`dashboard/nginx.conf`, réseau `host`, port 8083) ne relaie que `GET /api/v1/data` et `GET /api/v1/charts`, avec un micro-cache de 3 s.
- La température vient du graphique Netdata `sensors.temperature_cpu_thermal-virtual-0_temp1_input`. La vitesse du ventilateur n'est pas exposée par le Pi : la page affiche une valeur **estimée** d'après la courbe Argon (< 55 °C arrêté, 55 °C = 30 %, 60 °C = 55 %, 65 °C = 100 %). La mémoire par conteneur n'est pas disponible (comptabilité mémoire des cgroups désactivée par défaut sur Raspberry Pi OS).
- Dans l'interface Netdata, les capteurs se trouvent en cherchant `sensors` (et non `temp`).

### Les tiroirs par application

Chaque application est un tiroir (`<details>`) regroupant son conteneur nginx et son tunnel Cloudflare. La page les répartit en **deux catégories**, via le champ `category` de la liste `APPS` (`'main'` ou `'tech'`) :

**Applications** (`main`)

| Tiroir | Conteneurs |
|---|---|
| Site principal | `www` + `www-status` + `cloudflared-www` |
| GameVault | `gamevault` (Python) + `cloudflared-gamevault` |
| Homewatch | `homewatch` + `cloudflared-homewatch` |
| Web2 | `web2` + `cloudflared-web2` |

**Outils techniques et maintenance** (`tech`)

| Tiroir | Conteneurs |
|---|---|
| Dashboard | `dashboard` + `dashboard-sync` + `cloudflared-config` |
| Netdata | `netdata` + `cloudflared-netdata` |
| Logs (Dozzle) | `dozzle` + `cloudflared-logs` |
| Uptime Kuma | `uptime-kuma` + `cloudflared-uptime` |
| Autres conteneurs | tout conteneur non listé (ajouté automatiquement dans cette catégorie) |

Un conteneur qui apparaît dans « Autres conteneurs » avec « Image : ... » à la place du rôle manque à `APPS` / `DESCRIPTIONS` dans `dashboard/html/index.html`.

- **En-tête** : point de statut (vert si tout est en ligne, orange en partie, rouge si rien), nom, lien vers l'application (à droite, cliquable sans déplier), somme du CPU des conteneurs du tiroir, compteur « n/n en ligne ». Les colonnes CPU et « en ligne » ont une largeur fixe pour rester alignées d'un tiroir à l'autre ; sur écran étroit (< 700 px) le lien de l'en-tête est masqué (il reste dans le tiroir déplié).
- **Tiroir déplié** : lien d'accès, puis une ligne par conteneur (type Application / Tunnel / Service, nom cliquable vers ses logs dans Dozzle, rôle, état, CPU). L'état ouvert/fermé est mémorisé dans le navigateur (`localStorage`) et survit au rafraîchissement automatique (5 s).
- **Liens vers Dozzle** : Dozzle n'accepte que l'ID court du conteneur dans l'URL (`/container/<id>`), qui change à chaque recréation. Le conteneur `dashboard-sync` (image `docker:cli`, script `dashboard/sync.sh`) écrit toutes les 10 s `dashboard/data/containers.json` (id, nom, image uniquement, jamais la commande ni l'environnement), servi par nginx sur `/containers.json`.

### Ajouter une application au dashboard

Dans `dashboard/html/index.html` :
1. Ajouter une entrée dans la liste `APPS` : `{ id, category: 'main' | 'tech', name, url, members: ['<app>', 'cloudflared-<app>'] }` (`main` pour une application, `tech` pour un outil de maintenance)
2. Ajouter une description par conteneur dans `DESCRIPTIONS` (sinon la page affiche le nom de l'image)

Sans l'étape 1, les conteneurs apparaissent quand même, dans le tiroir « Autres conteneurs ».

### Tunnels et routes

Un tunnel Cloudflare par sous-domaine (`config`, `netdata`, `logs`, `uptime`), chacun avec son token dans `.env` (`CLOUDFLARE_TUNNEL_TOKEN_CONFIG`, `_NETDATA`, `_LOGS`, `_UPTIME`) et son conteneur `cloudflared-config` / `cloudflared-netdata` / `cloudflared-logs` / `cloudflared-uptime`. Routes (Published application routes) :

| Hostname | Service |
|---|---|
| `config.maximelabatut.com` | `http://localhost:8083` |
| `netdata.maximelabatut.com` (tunnel `netdata`) | `http://localhost:19999` |
| `logs.maximelabatut.com` | `http://localhost:8084` |
| `uptime.maximelabatut.com` | `http://localhost:8085` |

### Modifier le dashboard

Éditer `dashboard/html/index.html` directement via le partage Samba (`/Volumes/docker/dashboard/html/`) : nginx le sert en lecture seule à chaud, un simple rechargement de la page suffit (si le navigateur garde l'ancienne version : `Cmd+Maj+R`). Une modification de `nginx.conf` demande `docker compose restart dashboard`, une modification de `sync.sh` demande `docker compose restart dashboard-sync`.

### Alertes : Uptime Kuma + ntfy

**Uptime Kuma** (`uptime.maximelabatut.com`, image `louislam/uptime-kuma:2`, base **SQLite**, données dans `uptime-kuma/data/`, port `127.0.0.1:8085`) surveille les sites et envoie une alerte sur le téléphone via **ntfy** (notifications push). Le conteneur déclare `extra_hosts: host.docker.internal:host-gateway` pour pouvoir sonder des services du Pi (ports en réseau `host`).

**Mise en place (déjà faite, à refaire après une restauration)**

1. Créer le tunnel `uptime` (Zero Trust → Networks → Tunnels) et récupérer son token → `CLOUDFLARE_TUNNEL_TOKEN_UPTIME` dans `.env`.
2. **Avant** de publier la route : ajouter `uptime.maximelabatut.com` aux destinations de l'application Cloudflare Access (sinon le premier visiteur pourrait créer le compte administrateur), puis ajouter la route `uptime.maximelabatut.com` → `http://localhost:8085`.
3. `docker compose up -d`, puis ouvrir `https://uptime.maximelabatut.com` : choisir **SQLite**, créer le compte administrateur (mot de passe dans le gestionnaire de mots de passe).
4. ntfy : générer un nom de canal secret (`echo "homelab-$(openssl rand -hex 12)"`), installer l'application ntfy sur le téléphone et s'abonner au canal. Le nom du canal est le « mot de passe » : ne pas le partager ni le mettre dans git ou `.env` (Uptime Kuma ne lit pas ses réglages dans `.env` ; la notification est stockée dans sa base). Test indépendant depuis le Mac, sans laisser le canal dans l'historique :
   ```bash
   read -r -s -p "Canal ntfy : " T; echo
   curl -d "Test depuis le Mac" "https://ntfy.sh/$T"; echo
   unset T
   ```
5. Dans Uptime Kuma (menu du compte → **Paramètres → Notifications → Configurer une notification**) : type **Ntfy**, serveur `https://ntfy.sh`, le canal, priorité 4, cocher **Activé par défaut** et **Appliquer à toutes les sondes existantes**, puis **Tester**.
6. Ajouter les **sondes** (type HTTP(s), intervalle 60 s, nouvelles tentatives 2, soit une alerte après ~3 min) : `https://www.maximelabatut.com`, `https://gamevault.maximelabatut.com`, `https://web2.maximelabatut.com` (test de bout en bout, tunnel compris). Pour les outils derrière Access, les adresses publiques ne conviennent pas (Access répond avant le tunnel, la sonde resterait verte même tunnel tombé) : utiliser `http://host.docker.internal:8083` (dashboard) et `http://host.docker.internal:19999` (Netdata). Dozzle (lié à `127.0.0.1`) n'est pas joignable depuis le conteneur.

**Test réel (validé le 3 oct. 2026)** : `docker compose stop web2` → au bout de ~3 min, notification d'erreur **502** (le tunnel répond mais `web2` est arrêté) ; `docker compose start web2` → notification de retour **200**.

**Limites et restauration**
- Si le **Pi entier** tombe, Uptime Kuma tombe avec lui : aucune alerte ne part. Il faudrait une surveillance externe (heartbeat vers un service qui alerte en l'absence de signal).
- `uptime-kuma/data/` n'est **pas versionné** (il contient le compte administrateur, le hash de son mot de passe et le canal ntfy) mais il est **sauvegardé chaque jour** dans l'archive chiffrée du dépôt privé `maximelabatut-backups` (avec le `.env`) et **restauré automatiquement** par `restaurer-pi.sh` / `restore.sh` avant le premier lancement : après une restauration, le compte, les sondes et la notification ntfy sont déjà en place. Le dossier est créé par `restore.sh` pour qu'il appartienne à `maxime`.
- **Pourquoi pas un simple `cp` de `kuma.db`** : la base est en mode WAL. Le journal `kuma.db-wal` peut être plus gros que la base elle-même (1,1 Mo contre 380 Ko constatés) et contenir les écritures récentes. La sauvegarde utilise donc `sqlite3 .backup`, qui produit un instantané cohérent même pendant que Uptime Kuma écrit, plus `db-config.json` (sans lui, Uptime Kuma redemande le choix de la base de données). Le script vérifie `PRAGMA integrity_check` avant de chiffrer et d'envoyer quoi que ce soit.
- **`sudo` demande un mot de passe sur ce Pi** (il n'est pas en `NOPASSWD`). Le script de restauration (`restore.sh`) est donc exécuté avec un terminal (`ssh -t`) pour que `sudo` puisse le demander, et il maintient l'autorisation (`sudo -v` puis boucle `sudo -n true`) pour ne pas le redemander après les mises à jour. La sauvegarde quotidienne n'en a pas besoin : elle tourne en root via un timer systemd (cf. « Sauvegarde automatique »). `restore.sh` garde besoin du mot de passe `sudo` (une saisie).
- Les sondes et la notification sont sauvegardées automatiquement chaque jour (cf. « Sauvegarde automatique ») ; `sudo systemctl start homelab-backup` force une sauvegarde immédiate.
- Les sondes affichent le code HTTP renvoyé : `502` = tunnel joignable mais application arrêtée, `1033`/timeout = tunnel ou Pi injoignable.

### Consommation CPU de Netdata (réglages et diagnostic)

Config versionnée dans le repo et montée en lecture seule dans le conteneur `netdata` (elle survit à une restauration) :

| Fichier | Réglage | Effet |
|---|---|---|
| `netdata/netdata.conf` | `[db] update every = 2` | collecte toutes les 2 s au lieu de 1 s |
| `netdata/netdata.conf` | `[plugins] apps = no` | désactive `apps.plugin` (~960 graphiques par processus/utilisateur/groupe, le plus gros poste de CPU). La section « Processes / Apps » de l'interface Netdata disparaît ; le dashboard n'en dépend pas |
| `netdata/netdata.conf` | `[ml] enabled = yes` | détection d'anomalies (machine learning) conservée, son coût diminue avec le nombre de métriques suivies |
| `netdata/go.d/docker.conf` | job `local`, `update_every: 10`, `collect_container_size: no` | collecteur Docker ralenti (voir ci-dessous). Le nom `local` doit rester : le dashboard lit les graphiques `docker_local.*` |

Après modification d'un de ces fichiers : `docker restart netdata`.

**Diagnostic (3 oct. 2026)** : le Pi tournait à ~25 % de CPU (4 cœurs) alors que la somme des conteneurs ne dépassait pas ~8 % d'un cœur. En réalité `dockerd` et `containerd` consommaient chacun ~42 % d'un cœur, en dehors de tout conteneur. Dozzle arrêté n'a rien changé ; Netdata arrêté a fait passer `dockerd` de ~29 % à ~3-6 % : c'est son collecteur Docker (une interrogation de l'API toutes les 2 s) qui sollicitait le démon, d'où le passage à 10 s.

**Résultat mesuré après le passage à 10 s** (Netdata recréé avec `go.d/docker.conf`) :

| | `dockerd` | `containerd` | Système (4 cœurs) |
|---|---|---|---|
| Collecte Docker à 2 s | ~42 % d'un cœur | ~42 % | ~24 % |
| Collecte Docker à 10 s | **~14,6 %** (`top`, moyenne sur 60 s) | ~15 % | **~10 %** |

Gain : environ ×3 sur Docker, ×2,5 sur le CPU total du Pi. **Décision : on reste à 10 s** (réactivité de la détection d'incident, et ~15 % d'un cœur sur 4 est confortable). Le levier restant est l'intervalle : chaque collecte coûte ~1 s de CPU à `dockerd`, donc la moyenne est inversement proportionnelle à l'intervalle (30 s ≈ 5 %, 60 s ≈ 2 %, au prix d'un état de conteneur rafraîchi moins vite). Passer à 30 s demanderait de changer `update_every` dans `netdata/go.d/docker.conf` **et** d'élargir à 60 s la fenêtre de lecture des états dans le dashboard (`latest(chart, 20)`), sinon des cartes pourraient afficher « inconnu ».

**Mesurer correctement** : la consommation est **en pics** (~1 s de CPU toutes les 10 s). Un instantané de 5 s est trompeur (4 % ou 25 % selon qu'une collecte tombe dans la fenêtre). Utiliser une fenêtre de 60 s et lire la **deuxième** ligne (la première affiche la valeur depuis le démarrage du processus) ; sur le Pi, la colonne `%CPU` est la 9e :
```bash
top -b -n 2 -d 60 | awk '$NF=="dockerd" || $NF=="containerd"' | tail -2
```
Pour trouver un coupable : comparer avant/après avoir arrêté le conteneur suspect (`docker compose stop <service>`), puis le relancer. Avant de mesurer un réglage Netdata, vérifier qu'il est bien appliqué : le `update_every` des graphiques `docker_local.*` doit valoir 10 dans `http://localhost:19999/api/v1/charts` (une première mesure avait été faite par erreur sur l'ancien état, le conteneur n'ayant pas été recréé). Juste après un redémarrage, Netdata consomme davantage pendant quelques minutes (le ML réentraîne ses modèles) : attendre avant de mesurer. Dans le dashboard, les états de conteneurs sont lus sur une fenêtre de 20 s (`latest(chart, 20)`) pour tolérer cette collecte à 10 s.

Le dashboard met aussi en pause son rafraîchissement quand l'onglet est caché (`document.hidden`) : un aperçu ouvert dans un onglet en arrière-plan ne s'actualise donc pas.

### Température du Pi : valeurs de référence

| Température | Interprétation |
|---|---|
| < 60 °C | zone confortable (45-50 °C au repos est normal) |
| 60 à 70 °C | charge soutenue, acceptable |
| 70 à 80 °C | à surveiller |
| ≥ 80 °C | le processeur ralentit (throttling) |
| 85 °C | limite dure |

Vérifier qu'il n'y a jamais eu de ralentissement ni de sous-tension : `vcgencmd get_throttled` (`throttled=0x0` = tout va bien).

### Pourquoi Dozzle est lié à `127.0.0.1`

Le flux d'événements de Dozzle (`/api/events/stream`) renvoie la **ligne de commande complète de chaque conteneur, tokens Cloudflare compris** (`cloudflared ... tunnel run --token ...`). Avec `ports: "8084:8080"`, ce flux était lisible sans authentification par n'importe quel appareil du réseau local. Le compose publie donc Dozzle en `127.0.0.1:8084:8080` : seul le tunnel (réseau `host`) y accède, derrière Cloudflare Access. Si un token a été exposé, le régénérer (dashboard Cloudflare → tunnel → nouveau token) et mettre à jour `.env`.

Netdata (port 19999, réseau `host`) reste joignable depuis le réseau local : il n'expose pas les commandes des conteneurs, mais on peut aussi le restreindre à `127.0.0.1` (`[web] bind to = 127.0.0.1` dans `netdata.conf`) si besoin.

---

## GameVault (application Python)

Application personnelle : une page HTML (`GameVault.html`), un petit serveur Python (`rss_proxy_server.py`, bibliothèque standard uniquement, port 8787, qui relaie les requêtes du navigateur et gère le catalogue et la wishlist) et une base SQLite (`catalog.db`). Source de référence : le dépôt privé `github.com/maximelabatut/gamevault` (à l'origine un dossier Windows lancé en local par `run.bat`, depuis supprimé du Mac : tout est dans le dépôt, sur le Pi et dans la sauvegarde de la base).

### Hébergement sur le Pi

| Élément | Emplacement | Versionné dans le dépôt du homelab ? |
|---|---|---|
| Code (page, serveur, logos) | `~/docker/gamevault/app/` | non (`.gitignore`) |
| Base `catalog.db` | `~/docker/gamevault/data/` | non (`.gitignore`), sauvegardée sur le Mac |

Le service `gamevault` du `docker-compose.yml` utilise `python:3.12-slim`, lance `python rss_proxy_server.py` et publie `127.0.0.1:8081` → conteneur `8787` : la route du tunnel `gamevault.maximelabatut.com` → `http://localhost:8081` est inchangée. Le serveur sert aussi la page et les logos (`/`, `/logo.png`), donc tout passe par une seule adresse.

**Modifications du code d'origine** (minimales, le lancement local par `run.bat` fonctionne toujours) :
- `GAMEVAULT_HOST` (défaut `localhost`) : l'adresse d'écoute, à `0.0.0.0` dans Docker
- `GAMEVAULT_DB` : chemin de la base (défaut : `catalog.db` à côté du script)
- le serveur sert `GameVault.html`, `logo.png` et `logo.ico`
- dans le HTML, `API_BASE` vaut `http://localhost:8787` en `file://` et la même origine sinon (les 10 appels `http://localhost:8787/...` passent par cette constante)

### Accès : derrière Cloudflare Access

⚠️ Le serveur expose `/proxy?url=<n'importe quelle URL>` (téléchargement pour le compte du visiteur, sans restriction), des routes d'écriture sans authentification (`POST /games`, `/wishlist`, `DELETE /wishlist/<clé>`) et un CORS ouvert à tous. Publié sans protection, ce serait un **proxy ouvert** (accès possible aux services du réseau local, usage anonyme du Pi comme relais) avec une base modifiable par n'importe qui. `gamevault.maximelabatut.com` doit donc être dans les **destinations de l'application Cloudflare Access** (email + code + MFA), **avant** de lancer le conteneur : la route de tunnel existe déjà et serait publique dès son démarrage.

### Déploiement initial (une fois)

1. Cloudflare Access : ajouter `gamevault.maximelabatut.com` aux destinations de l'application.
2. Sur le Pi, le dossier `gamevault` appartenait à `root` (créé autrefois par Docker) : `sudo chown -R maxime:maxime ~/docker/gamevault`, puis `git pull`.
3. Installer le code (clone du dépôt privé avec la clé de déploiement, cf. plus bas) dans `~/docker/gamevault/app`, et déposer la base de départ (`catalog.db`) dans `~/docker/gamevault/data/`. Pour une restauration, `restore.sh` fait les deux.
4. Sur le Pi : `docker compose up -d gamevault www-status`, puis `docker compose logs gamevault | tail`.
5. Uptime Kuma : modifier la sonde GameVault et mettre l'URL `http://gamevault:8787/` (voir ci-dessous).
6. Forcer une sauvegarde (`sudo systemctl start homelab-backup`) pour que la base entre dans l'archive du jour.

### Mettre à jour le code

Le code de `~/docker/gamevault/app/` est un **clone du dépôt privé** `github.com/maximelabatut/gamevault`. Pousser les modifications dans le dépôt (depuis un clone de travail), puis sur le Pi :
```bash
git -C ~/docker/gamevault/app pull
cd ~/docker && docker compose restart gamevault
```

### Clé de déploiement (lecture seule)

Le dépôt étant privé, le Pi s'y authentifie avec une **clé de déploiement** : une clé SSH dédiée à ce seul dépôt, en **lecture seule**, qui n'expire pas.

- **Création (sur le Pi)** : `ssh-keygen -t ed25519 -N "" -C "gamevault-deploy@homelab" -f ~/.ssh/gamevault_deploy` (la partie privée reste sur le Pi, en `600`, et entre dans l'archive chiffrée quotidienne ; **ne jamais la versionner**).
- **Enregistrement** : GitHub → dépôt `gamevault` → Settings → Deploy keys → Add deploy key, avec le contenu de `~/.ssh/gamevault_deploy.pub`. ⚠️ **Ne pas cocher « Allow write access »**. Cette option ne peut pas être modifiée ensuite : pour la changer, supprimer la clé et la rajouter.
- **Sur le Pi** : `~/.ssh/gamevault_deploy` (`600`) et un bloc `Host github-gamevault` dans `~/.ssh/config` (`IdentityFile`, `IdentitiesOnly yes`) ; le dépôt se clone avec `git clone git@github-gamevault:maximelabatut/gamevault.git`. `restore.sh` fait tout cela à la restauration.
- **Tester qu'elle est bien en lecture seule** : tenter un `git push` vers une **branche jetable** (`git push origin HEAD:refs/heads/_test-lecture-seule`), jamais vers `main`. Le refus attendu : `The key you are authenticating with has been marked as read only`. (Un test sur `main` avec une clé qui s'avérerait inscriptible laisserait un commit dans l'historique : c'est arrivé une fois, nettoyé par push forcé protégé.)
- **Empreintes de `github.com`** : en cas d'avertissement `REMOTE HOST IDENTIFICATION HAS CHANGED`, ne rien contourner. Comparer d'abord les empreintes présentées (`ssh-keyscan github.com | ssh-keygen -lf -`) aux empreintes officielles (`curl -s https://api.github.com/meta`, champ `ssh_key_fingerprints`). Si elles correspondent, l'entrée du `known_hosts` est simplement périmée : `ssh-keygen -R github.com`, puis ré-enregistrer les clés vérifiées. Si elles diffèrent : s'arrêter, c'est peut-être une interception. `restore.sh` utilise `StrictHostKeyChecking accept-new` : la première connexion enregistre la clé de GitHub sans la vérifier.

### Surveillance et statut public

- **Page d'accueil (www)** : la carte GameVault reste affichée. `www-status` ne peut plus tester l'URL publique (Cloudflare Access répondrait par sa page de connexion) : il teste l'application par son nom sur le réseau Docker, `http://gamevault:8787/` (`www/status.sh`).
- **Uptime Kuma** : même raison, remplacer l'URL de la sonde `gamevault.maximelabatut.com` par `http://gamevault:8787/` (les services d'un même `docker-compose.yml` partagent un réseau et se joignent par leur nom ; `host.docker.internal` ne convient pas, le port n'étant publié que sur `127.0.0.1`).

### Sauvegarde et restauration

- `homelab-backup` (Pi) prend un instantané cohérent de la base (`sqlite3 .backup`), le vérifie (`PRAGMA integrity_check`) et l'ajoute à l'archive chiffrée du jour (`gamevault-data.tgz` dedans, environ 5 Mo pour ~2 500 jeux), avec le `.env` et les données d'Uptime Kuma.
- `restaurer-pi.sh` déchiffre l'archive et envoie la **clé de déploiement** et `gamevault-data.tgz` ; `restore.sh` **clone le dépôt privé** dans `~/docker/gamevault/app` (code toujours à jour) et restaure la base dans `~/docker/gamevault/data`, avant le premier lancement. L'export ne transporte donc que la **base**, plus de code.
- Le code est versionné dans le dépôt **privé** `github.com/maximelabatut/gamevault` (2 commits : la version d'origine, puis les adaptations Docker ; sans `catalog.db`, `run.bat` ni `.claude`) et c'est **lui la source de vérité** du code. Ce dépôt doit rester **privé**. Le dossier `GameVault` qui existait sur le Mac a été supprimé : plus aucune copie locale n'est nécessaire.

---

## Sauvegarde automatique (chiffrée, sur GitHub)

Le **Pi sauvegarde lui-même**, chaque jour, vers un dépôt GitHub **privé** dédié (`github.com/maximelabatut/maximelabatut-backups`). Le Mac n'intervient plus : il peut être éteint, absent ou remplacé. Les archives sont **chiffrées avant l'envoi** avec `age` (clé asymétrique) : GitHub ne voit que des blocs illisibles, et le Pi lui-même ne détient que la clé *publique* (il ne peut pas relire ses propres sauvegardes : compromettre le Pi ne livre pas l'historique).

| Où | Quoi |
|---|---|
| Pi | `/usr/local/sbin/homelab-backup` (root, `755`), lancé par `homelab-backup.service` + `homelab-backup.timer` (tous les jours ~03h30, `Persistent=true`, rattrapage au démarrage si le Pi était éteint) |
| Pi | `/etc/homelab-backup/` (root, `700`) : `recipient` (clé publique : celle de `id_ed25519_homelab`), `deploy-key` (clé SSH **en écriture**, propre au dépôt de sauvegardes), `known_hosts` (clés officielles de GitHub, issues de `api.github.com/meta`), `push-url` (facultatif, cf. plus bas) |
| Pi | `/var/lib/homelab-backup/repo` : clone de travail ; `/usr/local/sbin/homelab-check-access` : contrôle d'exposition (cf. « Contrôle d'accès ») |
| Dépôt | `pi/homelab-backup`, `pi/homelab-backup.{service,timer}`, `pi/verifier-acces.sh`, `pi/install-backup.sh` |
| GitHub | `maximelabatut-backups` (privé) : un commit unique contenant `homelab-AAAA-MM-JJ.tar.gz.age` pour les 30 derniers jours |
| Mac + gestionnaire de mots de passe | la clé SSH **`~/.ssh/id_ed25519_homelab`** (protégée par sa phrase secrète) : seule capable de déchiffrer. Le fichier de clé et la phrase doivent être aussi dans le gestionnaire de mots de passe |

**Contenu d'une archive** : `env` (tokens Cloudflare), `uptime-kuma-data.tgz`, `gamevault-data.tgz`, `gamevault-deploy-key`, `homewatch-deploy-key`, `homelab-backup/` (clé publique age, clé d'écriture, URL de push), `MANIFEST.txt`. Un seul fichier à télécharger, une seule clé pour tout restaurer.

### Mise en place (une fois)

1. **Sur le Mac** : `brew install age`, puis afficher la clé **publique** SSH : `cat ~/.ssh/id_ed25519_homelab.pub` (une ligne `ssh-ed25519 AAAA...`, non secrète). C'est elle qui chiffre les sauvegardes ; la clé **privée** (`id_ed25519_homelab`, protégée par sa phrase secrète) les déchiffre. Aucune nouvelle clé à créer. Vérifier que le fichier de clé et sa phrase sont bien dans le gestionnaire de mots de passe. Ne jamais envoyer la clé privée à qui que ce soit, ni la mettre sur le Pi ou dans git.
2. **Dépôt GitHub** : privé, vide (`maximelabatut-backups`).
3. **Sur le Pi** : `cd ~/docker && git pull && sudo bash pi/install-backup.sh`. Le script installe `age`, le timer et les scripts, demande la clé **publique** (la ligne `ssh-ed25519 AAAA...` de l'étape 1 ; une clé `age1...` est aussi acceptée), génère la clé d'écriture et affiche sa partie publique. L'ajouter dans GitHub → `maximelabatut-backups` → Settings → Deploy keys → Add deploy key, en **cochant « Allow write access »** (cette option ne peut pas être modifiée ensuite), puis Entrée : le script propose de lancer la première sauvegarde.
4. **Vérifier** : le fichier `homelab-AAAA-MM-JJ.tar.gz.age` apparaît sur GitHub ; le télécharger et contrôler qu'il se déchiffre (`age -d -i ~/.ssh/id_ed25519_homelab fichier.age | tar tzv` ; `age` demande la phrase secrète de la clé, qu'il ne reprend pas du Trousseau). **Une sauvegarde jamais testée n'est pas une sauvegarde.**
5. **Alerte (recommandé)** : dans Uptime Kuma, ajouter un moniteur de type **Push** (« Heartbeat Interval » 90000 s ≈ 25 h, notification ntfy). Copier l'URL de push **sans** les paramètres (`http://localhost:8085/api/push/<jeton>`) dans `/etc/homelab-backup/push-url` (`sudo`, droits `600`). Le script envoie « up » après chaque réussite et « down » en cas d'échec ou d'exposition détectée ; sans nouvelle pendant 25 h (Pi éteint, GitHub inaccessible), Kuma alerte aussi.

### Fonctionnement d'une exécution

1. Instantanés cohérents des bases (`sqlite3 .backup`), `PRAGMA integrity_check` ; arrêt immédiat si une base est corrompue.
2. Copie du `.env` (arrêt s'il n'y a aucun token Cloudflare valide) et des clés de déploiement.
3. Archive fabriquée **en mémoire** (`/dev/shm`) puis chiffrée à la volée : aucun secret n'est écrit en clair sur la carte SD.
4. Envoi : récupération de l'état distant, ajout de l'archive du jour, suppression au-delà de 30, **commit racine** puis push forcé (l'historique n'est pas conservé : sinon l'ancienne archive resterait dans git et le dépôt grossirait sans fin). Vérification que GitHub a bien le commit, puis nettoyage (`gc --prune=now`). Poids total : ~150 Mo pour 30 archives.
5. Contrôle d'exposition (cf. « Contrôle d'accès »).

En cas d'échec avant l'envoi, **rien n'est remplacé** sur GitHub. Suivi : `journalctl -u homelab-backup -n 30 --no-pager`, prochaine exécution : `systemctl list-timers homelab-backup`, forcer : `sudo systemctl start homelab-backup`.

**Limites et sécurité (à connaître)**
- **La clé SSH `id_ed25519_homelab` est le point unique de défaillance** : perdue (sans copie), toutes les sauvegardes sont définitivement illisibles *et* l'accès SSH au Pi aussi ; volée avec sa phrase et l'accès au dépôt, les sauvegardes sont toutes lisibles (tokens Cloudflare, base d'Uptime Kuma, clés de déploiement). Le fichier de clé (chiffré par sa phrase) et la phrase doivent être dans le gestionnaire de mots de passe, avec une copie hors ligne. **Si on la remplace** (nouvelle clé SSH), les archives existantes restent chiffrées pour l'ancienne : la conserver 30 jours, mettre la nouvelle clé publique dans `/etc/homelab-backup/recipient` (une seule ligne). Si elle fuit : changer la clé, **faire tourner les tokens Cloudflare** (ils sont dans les anciennes archives) et recréer le dépôt de sauvegardes.
- La clé d'écriture sur le Pi permet de **détruire** les sauvegardes (push forcé) si le Pi est compromis, mais pas de les lire. Un exemplaire hors ligne de temps en temps (téléchargement manuel de la dernière archive) couvre ce cas.
- Le script root refuse tout chemin contenant un lien symbolique (`realpath -e`) et ne lit que des fichiers de `maxime`; son résultat est chiffré pour une clé que `maxime` ne détient pas. `maxime` est dans le groupe `docker`, donc équivalent root de toute façon : ce n'est pas une barrière contre quelqu'un qui contrôle déjà ce compte.
- Dépend de GitHub (disponibilité, et du compte : activer la double authentification). Un envoi qui échoue ne détruit rien ; il est rejoué le lendemain.
- Les anciens instantanés non chiffrés (`/var/backups/homelab/`, règle `sudo` dédiée) sont supprimés par `install-backup.sh`.

---

## Homewatch (application privée)

Application privée de visualisation, développée à part : son code vit dans le dépôt **privé** `github.com/maximelabatut/homewatch`, dont le `README.md` détaille le fonctionnement, la configuration et la sécurité. Ici, seulement ce qu'il faut pour l'héberger. **Volontairement sobre** : cette documentation est publique, les détails de l'application restent dans le dépôt privé.

| Élément | Emplacement | Versionné dans le dépôt du homelab ? |
|---|---|---|
| Code | `~/docker/homewatch/app/` (clone du dépôt privé) | non (`.gitignore`) |
| Données (jeton de session) | `~/docker/homewatch/data/` | non (`.gitignore`) et **jamais exportées** |
| Segments vidéo temporaires | `tmpfs` en mémoire (`/run/hls`) | non, éphémères (aucune écriture sur la carte SD) |

Le service `homewatch` est construit sur place (`build: ./homewatch/app`, image Python + ffmpeg) et durci : utilisateur non root (`1000:1000`), système de fichiers en lecture seule, aucune capacité Linux (`cap_drop: ALL`), `no-new-privileges`, mémoire limitée à 512 Mo **dans le compose mais non appliquée sur ce Pi** (voir ci-dessous), port publié sur `127.0.0.1:8086` uniquement.

**Limite mémoire non appliquée** : au démarrage, Docker affiche `Your kernel does not support memory limit capabilities or the cgroup is not mounted. Limitation discarded.` Raspberry Pi OS désactive par défaut le contrôle de mémoire des cgroups : `mem_limit` est donc ignoré, ici comme pour tous les conteneurs (c'est aussi pourquoi le dashboard n'affiche pas la mémoire par conteneur). L'activer demande d'ajouter `cgroup_enable=memory cgroup_memory=1` à la **fin de l'unique ligne** de `/boot/firmware/cmdline.txt` puis de redémarrer ; non fait à ce jour, la ligne du compose reste en place pour le jour où ce sera activé.

### Accès : uniquement derrière Cloudflare Access + MFA

⚠️ L'application n'a **aucune authentification propre**. `homewatch.maximelabatut.com` doit donc être dans les destinations de l'application Cloudflare Access (email + code + MFA) **avant** de publier la route du tunnel, et ne doit **jamais** être rendue publique. Après la mise en place, vérifier avec `~/docker/pi/verifier-acces.sh` (cf. « Contrôle d'accès ») que l'adresse répond par la redirection vers Cloudflare Access et pas par l'application.

### Mise en place (une fois)

1. **Clé de déploiement** (lecture seule), créée sur le Pi : `ssh-keygen -t ed25519 -N "" -C "homewatch-deploy@homelab" -f ~/.ssh/homewatch_deploy`, puis GitHub → dépôt `homewatch` → Settings → Deploy keys → Add deploy key, avec le contenu de `~/.ssh/homewatch_deploy.pub`, **sans cocher « Allow write access »** (une clé par dépôt : celle de GameVault ne peut pas servir ici).
2. **Cloudflare** : tunnel `homewatch` (token dans `.env` : `CLOUDFLARE_TUNNEL_TOKEN_HOMEWATCH`) ; ajouter `homewatch.maximelabatut.com` aux destinations Access ; **puis** ajouter la route → `http://localhost:8086`.
3. **Sur le Pi** : ajouter le bloc `Host github-homewatch` dans `~/.ssh/config` (`IdentityFile ~/.ssh/homewatch_deploy`, `IdentitiesOnly yes`) et cloner : `git clone git@github-homewatch:maximelabatut/homewatch.git ~/docker/homewatch/app`.
4. **Construire et se connecter** (le code de vérification à deux facteurs se saisit au terminal) :
```bash
cd ~/docker
docker compose build homewatch
docker compose run --rm homewatch     # e-mail, mot de passe, code ; Ctrl-C après « Connecté »
docker compose up -d homewatch cloudflared-homewatch
```
5. **Uptime Kuma** : sonde HTTP `http://homewatch:5000/` (réseau Docker partagé).

### Mettre à jour

```bash
git -C ~/docker/homewatch/app pull
cd ~/docker && docker compose up -d --build homewatch
```

### Sauvegarde et restauration

- Le **code** est cloné par `restore.sh` avec la clé `homewatch-deploy-key` (contenue dans l'archive chiffrée, envoyée par `restaurer-pi.sh`), comme pour GameVault.
- Le fichier de session **ne contient que des jetons** (ni e-mail ni mot de passe, retirés à chaque écriture). Il n'est volontairement **pas sauvegardé** : un jeton reste un accès au compte, et une copie de plus sur GitHub augmenterait inutilement l'exposition. Il ne peut pas être une valeur fixe dans `.env` : le jeton de renouvellement change à chaque usage et l'application l'enregistre elle-même. Après une restauration, refaire la première connexion (`docker compose run --rm homewatch`, ~2 minutes) ; `restore.sh` le rappelle en fin d'exécution. Tant qu'elle n'est pas faite, le conteneur s'arrête avec un message explicite et redémarre en boucle sans rien exposer.
- Sans jeton valide ni terminal (jeton révoqué, très longue panne), le conteneur échoue (code 2) plutôt que d'attendre une saisie : relancer `docker compose run --rm homewatch`.

---

## Page d'accueil publique (www.maximelabatut.com)

Vitrine du homelab : `www/html/index.html`, une page statique sans dépendance externe (fond crème, accents terracotta, polices système). Sections : accueil avec pastille d'état en direct, cartes des applications (GameVault, Web2) avec statut, schéma du trajet d'une visite (visiteur → Cloudflare → tunnel → Raspberry Pi → Docker, vertical sur mobile), technologies utilisées, contact (GitHub). Les animations respectent `prefers-reduced-motion`.

### Statut en direct

Le conteneur `www-status` (image `curlimages/curl`, script `www/status.sh`, `user: root`) teste toutes les 30 s les **URL publiques** des trois sites (`www`, `gamevault`, `web2`, donc tunnel et Cloudflare compris, un site est « en ligne » s'il répond `200`) et écrit `www/html/data/status.json` :

```json
{"updated":1791057649,"uptime_seconds":25290,"services":{"www":true,"gamevault":true,"web2":true}}
```

Seuls « en ligne / hors ligne » et l'uptime sont publics : aucune métrique sensible. Côté page, le fichier est relu toutes les 30 s ; s'il est absent, vide ou plus vieux que 3 minutes, la pastille affiche « Statut du serveur indisponible pour le moment » (plutôt qu'un faux « en ligne »).

### Modifier la page

- Éditer `www/html/index.html` via le partage Samba (rechargement avec `Cmd+Maj+R`). Les descriptions des cartes sont des textes à adapter dans le HTML.
- Pour ajouter une application : une carte `<article class="card">` avec un `data-status="<clé>"` et son entrée dans `NAMES` (script de la page), et la clé correspondante dans `www/status.sh`.
- Aucune adresse email n'est publiée volontairement : seul le lien GitHub figure dans la section contact.

### Fichiers générés (à ne pas versionner)

`www/html/data/status.json` et `dashboard/data/containers.json` sont réécrits en permanence par leurs conteneurs : les ajouter au `.gitignore` pour éviter du bruit dans git. Créer les dossiers avant le premier lancement pour qu'ils appartiennent à `maxime` (cf point de vigilance n°1) :
```bash
mkdir -p ~/docker/www/html/data ~/docker/dashboard/data
```

⚠️ **Piège rencontré** : le fichier de statut doit se trouver **dans** `www/html/`, servi par le montage existant. Monter un second dossier à l'intérieur (`./www/data:/usr/share/nginx/html/data`) échoue, car `www/html` est lui-même monté en lecture seule : `mkdirat ... read-only file system` et `www` ne démarre pas. `www-status` écrit donc directement dans `./www/html/data`, que `www` lit en lecture seule.

---

## Sécuriser avec Cloudflare Access + MFA

⚠️ Netdata et Dozzle donnent accès à des informations sensibles (Dozzle lit le socket Docker, équivalent à un accès root). **Ne jamais exposer ces sous-domaines sans Access.** Dozzle reste en lecture seule : laisser désactivés « Démarrer/arrêter » et « Shell » dans son assistant de configuration.

### Application Access (Zero Trust → Access controls → Applications → Add an application)

1. Type **Self-hosted and private**, sous-onglet **Public DNS**
2. Destinations : `config.maximelabatut.com`, `logs.maximelabatut.com`, `netdata.maximelabatut.com`, `uptime.maximelabatut.com` (tout nouveau sous-domaine sensible doit y être ajouté)
3. Policy : **Allow**, règle **Emails** = ton adresse (ex. policy « Moi uniquement »)
4. Authentication : laisser « Accept all available identity providers » (One-time PIN par email)
5. MFA : **Customize MFA settings** → Authenticator application, durée 24 h

### Enrôler l'authentificateur (une seule fois)

L'enrôlement MFA passe par l'**App Launcher**, qui doit être activé (Access controls → Access settings → App Launcher, avec la même policy « Moi uniquement » rattachée). Sans ça, le bouton « Setup MFA » renvoie sur une page « Welcome! Please contact your administrator… » et la page « No authentication methods set up » revient en boucle.

Lien direct d'enrôlement : `https://holy-silence-502a.cloudflareaccess.com/AddMfaDevice` (email, code reçu par mail, puis scan du QR code et saisie du code à 6 chiffres jusqu'à validation).

Après l'enrôlement, Cloudflare peut te renvoyer sur la page d'accueil de l'organisation : retaper simplement l'URL du site voulu.

### Contrôle d'accès (verifier-acces.sh)

`pi/verifier-acces.sh` (installé sur le Pi sous `/usr/local/sbin/homelab-check-access`) vérifie, **sans être connecté et par le chemin public** (DNS puis Cloudflare, comme n'importe quel visiteur), que chaque sous-domaine est protégé par Access (ou public) comme prévu. Une application derrière Access répond **toujours** par un `302` vers `*.cloudflareaccess.com`, même si son conteneur est arrêté : toute autre réponse (200, 5xx, redirection ailleurs) veut dire qu'Access ne l'intercepte pas, donc une **exposition**.

| Sous-domaines | Attendu |
|---|---|
| `www`, `web2` | publics (HTTP 200) |
| `config`, `netdata`, `logs`, `uptime`, `gamevault`, `homewatch` | derrière Access (302 vers `cloudflareaccess.com`) |

- Lancement manuel : `~/docker/pi/verifier-acces.sh` (tableau complet ; code de sortie 0 = conforme, 1 = anomalie, 2 = pas de réseau). `--quiet` n'affiche que les anomalies.
- **À chaque sauvegarde (une fois par jour)**, `homelab-backup` le lance en dernier : en cas d'anomalie, ligne `EXPOSITION DÉTECTÉE` dans `journalctl -u homelab-backup` et, si le moniteur Push d'Uptime Kuma est configuré, alerte ntfy (la sauvegarde elle-même est déjà faite).
- **Règle** : toute nouvelle application ajoutée au `docker-compose.yml` doit être ajoutée aux listes `PUBLIC_HOSTS` / `PROTECTED_HOSTS` de `pi/verifier-acces.sh` (puis `sudo bash pi/install-backup.sh` pour recopier la version installée), sinon elle n'est pas contrôlée.
- Origine : lors de la mise en place d'Homewatch, ce contrôle a révélé qu'`uptime.maximelabatut.com` était resté **sans Access** (sa page de connexion Uptime Kuma était joignable de l'extérieur). L'oubli de l'étape « ajouter l'adresse aux destinations Access » ne se voit pas à l'usage, puisque l'application fonctionne quand même.

### Tester

Ouvrir le site en navigation privée : email, code reçu par mail, code de l'application d'authentification, puis le service. Si le site s'affiche sans aucune demande de connexion, la destination n'est pas rattachée à l'application Access.

---

## 0. Convention à respecter

- Dossier du service : `~/docker/<nom-service>/html`
- Port local : le prochain port libre (8080 = www, 8081 = gamevault, 8082 = web2, 8083 = dashboard (`config.`), 8084 = Dozzle (`logs.`), 8085 = Uptime Kuma (`uptime.`), 8086 = Homewatch (privé), 19999 = Netdata (réseau `host`), → 8087 pour le suivant, etc.)
- Sous-domaine : `<nom-service>.maximelabatut.com`
- Nom du tunnel Cloudflare : un nom explicite (ex: `raspberry-<nom-service>`)
- Nom de variable token dans `.env` : `CLOUDFLARE_TUNNEL_TOKEN_<NOM_SERVICE>` (en majuscules)

---

## 1. Créer le dossier et le contenu du service

```bash
mkdir -p ~/docker/<nom-service>/html
echo "<h1><nom-service></h1>" > ~/docker/<nom-service>/html/index.html
```

⚠️ **Point de vigilance n°1** : si le dossier est créé automatiquement par Docker (parce qu'on lance le conteneur avant de créer le dossier soi-même), il appartient à `root` et `maxime` ne peut plus y écrire → **403 Forbidden** garanti. Toujours créer le dossier **manuellement en premier**, avec `mkdir -p` en tant que `maxime`, avant de lancer le conteneur.

Si le problème survient quand même :
```bash
sudo chown -R maxime:maxime ~/docker/<nom-service>
```

---

## 2. Créer le tunnel Cloudflare (dashboard, depuis le Mac)

1. Aller sur [one.dash.cloudflare.com](https://one.dash.cloudflare.com) (Zero Trust) → **Networks → Tunnels → Create a tunnel**
2. Connecteur : **Cloudflared**
3. Nom : `raspberry-<nom-service>`
4. Copier le **token** affiché (longue chaîne commençant par `eyJ...`) — ne pas exécuter la commande proposée telle quelle, on l'intègre à Docker Compose.

### Configurer la route publique (onglet « Published application routes »)

Dans l'interface actuelle, l'ancien « Public Hostname » s'appelle **Published application routes** (onglet en haut de la page du tunnel, à côté de « Hostname routes »).

| Champ | Valeur |
|---|---|
| Subdomain | `<nom-service>` |
| Domain | `maximelabatut.com` |
| Service | `http://localhost:<port>` |

⚠️ **Point de vigilance n°4** : le service doit être en **`http://`** et non `https://`. Les conteneurs nginx parlent en HTTP simple (le HTTPS est géré par Cloudflare en façade). Avec `https://localhost:<port>`, le tunnel se connecte mais renvoie une erreur 502, et les logs `cloudflared` affichent `tls: first record does not look like a TLS handshake`.

⚠️ **Point de vigilance n°2** : bien sauvegarder la route avant de quitter la page. Une entrée non sauvegardée ne crée pas le CNAME DNS → le site répondra en `NXDOMAIN` alors que le tunnel tourne normalement (symptôme trompeur : les logs `cloudflared` semblent parfaitement sains).

Vérification possible dans `dash.cloudflare.com` (dashboard classique, pas Zero Trust) → domaine → **DNS → Records** : une ligne de type `CNAME`/`Tunnel`, nom `<nom-service>`, **Proxied** (nuage orange).

---

## 3. Ajouter le token dans `.env`

```bash
nano ~/docker/.env
```
Ajouter une ligne :
```
CLOUDFLARE_TUNNEL_TOKEN_<NOM_SERVICE>=colle_le_token_ici
```

---

## 4. Ajouter les 2 services dans `docker-compose.yml`

```bash
nano ~/docker/docker-compose.yml
```

Ajouter sous `services:` :
```yaml
  <nom-service>:
    image: nginx
    container_name: <nom-service>
    restart: unless-stopped
    ports:
      - "<port>:80"
    volumes:
      - ./<nom-service>/html:/usr/share/nginx/html:ro

  cloudflared-<nom-service>:
    image: cloudflare/cloudflared:latest
    container_name: cloudflared-<nom-service>
    restart: unless-stopped
    network_mode: host
    command: tunnel run --token ${CLOUDFLARE_TUNNEL_TOKEN_<NOM_SERVICE>}
```

---

## 5. Lancer

```bash
cd ~/docker
docker compose up -d
docker compose ps
```

Vérifier que les deux nouveaux conteneurs sont bien `Up` (pas `Restarting`).

---

## 6. Vérifier le tunnel

```bash
docker compose logs cloudflared-<nom-service>
```

Doit se terminer par plusieurs lignes `Registered tunnel connection` et un bloc **CONNECTIVITY PRE-CHECKS** tout en `PASS`.

Si `Provided Tunnel token is not valid` → le token dans `.env` est mal copié (vérifier `docker compose config | grep -A2 cloudflared-<nom-service>` pour voir la valeur réellement injectée).

---

## 7. Vérifier le DNS et l'accès, en ignorant les caches locaux

```bash
dig <nom-service>.maximelabatut.com @1.1.1.1
```
Doit renvoyer une `ANSWER SECTION` avec des IPs `188.114.x.x` (IPs proxy Cloudflare).

Test bout-en-bout qui contourne totalement le DNS local (utile pour ne pas se faire piéger par le cache DNS de la box, cf point de vigilance n°3) :
```bash
curl -s --resolve <nom-service>.maximelabatut.com:443:188.114.97.2 https://<nom-service>.maximelabatut.com | head -5
```
Si ça retourne du HTML → le backend est 100% fonctionnel, tout problème restant est côté cache DNS local.

⚠️ **Point de vigilance n°3** : la box internet (Free/Orange/SFR/Bouygues...) met en cache une réponse `NXDOMAIN` si on teste l'URL **avant** que le CNAME existe, et garde ce cache négatif potentiellement plusieurs dizaines de minutes — même après correction côté Cloudflare. Symptôme : `dig <site>.maximelabatut.com` (sans `@1.1.1.1`) renvoie `NXDOMAIN` alors que tout fonctionne par ailleurs. Ce n'est pas un bug de la config, ça se résout tout seul avec le temps, ou en forçant le DNS du Mac sur `1.1.1.1` / `1.0.0.1` (Réglages Système → Réseau → Wi-Fi → Détails → DNS).

---

## 8. Test final navigateur

```
https://<nom-service>.maximelabatut.com
```

---

## 9. Ajouter l'application au dashboard

Ajouter le nouveau service (et son tunnel) dans `APPS` et `DESCRIPTIONS` de `dashboard/html/index.html` (cf section « Ajouter une application au dashboard ») **et** aux listes de `verifier-acces.sh` (cf. « Contrôle d'accès »). Si le sous-domaine donne accès à quelque chose de sensible (outil d'admin, métriques, logs), l'ajouter aussi aux destinations de l'application Cloudflare Access **avant** de l'utiliser.

---

## Accès fichiers via Samba

Rien à faire : `~/docker` est déjà partagé en entier (`smb://maxime.local/docker`). Le nouveau dossier `<nom-service>/` apparaît automatiquement dans le partage dès qu'il est créé à l'étape 1.

Sur le Mac, le partage monté (Finder → `Cmd+K` → `smb://maxime.local/docker`) est accessible à `/Volumes/docker`. On peut y créer les dossiers, modifier `docker-compose.yml` et éditer les pages directement depuis le Mac, sans SSH. Seule la commande `docker compose up -d` doit être lancée sur le Pi, en SSH.

Les fichiers parasites macOS (`.DS_Store`, `._*`) créés par le Finder sont exclus de git via `.gitignore`.

---

## Récapitulatif des erreurs rencontrées et leur cause

| Symptôme | Cause | Fix |
|---|---|---|
| `403 Forbidden` (nginx) | Dossier `html` vide, ou créé par Docker (appartient à `root`) | `mkdir -p` avant de lancer le conteneur ; sinon `sudo chown -R maxime:maxime ~/docker/<service>` |
| Erreur Cloudflare `1033` | Conteneur `cloudflared` du tunnel concerné arrêté/en erreur | `docker compose ps` puis `docker compose logs cloudflared-<service>` |
| `Provided Tunnel token is not valid` | Token mal copié dans `.env`, ou nom de variable qui ne correspond pas entre `.env` et `docker-compose.yml` | Recopier le token en entier depuis le dashboard, vérifier avec `docker compose config` |
| `dig` renvoie `NXDOMAIN` en local mais `@1.1.1.1` répond bien | Cache DNS négatif de la box internet | Attendre, ou forcer `1.1.1.1` en DNS sur le Mac |
| `dig` renvoie `NXDOMAIN` même via `@1.1.1.1` | La route n'a pas été sauvegardée côté tunnel (CNAME jamais créé) | Recréer/re-sauvegarder l'entrée dans Zero Trust → Tunnels → onglet Published application routes |
| `502 Bad Gateway`, logs `tls: first record does not look like a TLS handshake` | Service configuré en `https://localhost:<port>` au lieu de `http://` | Éditer la route dans Published application routes et mettre `http://localhost:<port>` (pris en compte sans redémarrer le conteneur) |
| `502 Bad Gateway`, logs `connection refused` | Le conteneur nginx est arrêté, ou le port de la route ne correspond pas au port publié dans `docker-compose.yml` | `docker compose ps`, `curl -I http://localhost:<port>` sur le Pi, vérifier la correspondance des ports |
| `Provided Tunnel token is not valid` alors que le token vient d'être copié, et `DOCKER_GID variable is not set` | `echo "DOCKER_GID=..." >> .env` sur un fichier sans retour à la ligne final : la valeur s'est collée à la fin d'un token | `sed -i 's/DOCKER_GID=[0-9]*$//' .env`, puis `echo "" >> .env` et réajouter `DOCKER_GID` ; `docker compose up -d` recrée les conteneurs avec la bonne valeur |
| Erreur `Unexpected token '<'` sur un sous-domaine qui servait autre chose avant | Service worker / cache de l'ancienne interface (ex. Netdata) dans le navigateur | Navigation privée, ou Paramètres du site → Effacer les données puis `Cmd+Maj+R` |
| Page Access « No authentication methods set up » en boucle | App Launcher non activé : impossible d'enrôler le MFA | Activer l'App Launcher avec une policy, puis ouvrir `https://<équipe>.cloudflareaccess.com/AddMfaDevice` |
| Erreur Cloudflare `1033` sur un sous-domaine dont la route existe bien | Le tunnel a été créé sur le dashboard Cloudflare mais **aucun conteneur `cloudflared-<service>` ne le fait tourner** (service et token absents du compose / `.env`), ou la route a été créée sur un autre tunnel | Ajouter le service `cloudflared-<service>` et `CLOUDFLARE_TUNNEL_TOKEN_<SERVICE>` ; vérifier quelles routes un tunnel connaît avec `docker compose logs cloudflared-<service> \| grep "Updated to new configuration" \| tail -1` (liste des hostnames) |
| `www` ne démarre pas, `mkdirat ... read-only file system` | Volume monté à l'intérieur d'un dossier déjà monté en lecture seule (ex. `./www/data` dans `/usr/share/nginx/html`) | Placer le dossier dans l'arborescence déjà montée (`www/html/data`) au lieu d'un second montage |
| « Statut du serveur indisponible pour le moment » sur la page d'accueil | `status.json` absent, périmé (> 3 min) ou non servi : `www-status` arrêté, ou `www` jamais recréé avec le bon montage (404 sur `/data/status.json`) | `docker compose up -d --force-recreate www www-status`, puis `cat www/html/data/status.json` et `curl -s http://localhost:8080/data/status.json` |
| `"www":false` ponctuel dans `status.json` | Test réalisé pendant le redémarrage de `www` | Transitoire : le cycle suivant (30 s) remet à `true` |
| Conteneur affiché dans « Autres conteneurs » avec « Image : ... » | Absent de `APPS` / `DESCRIPTIONS` dans le dashboard | Ajouter le conteneur à un tiroir de `dashboard/html/index.html` |
| Dozzle « Conteneur non trouvé » depuis un lien du dashboard | Le lien utilise l'ID du conteneur, qui change quand il est recréé ; `containers.json` n'est pas encore à jour, ou `dashboard-sync` est arrêté | Attendre 10 s et recharger ; vérifier `docker compose ps` pour `dashboard-sync` |
| Noms de conteneurs non cliquables dans le dashboard | `/containers.json` absent (`dashboard-sync` jamais lancé ou dossier `dashboard/data` manquant) | `docker compose up -d`, vérifier que `~/docker/dashboard/data/containers.json` existe |
| Aucune température visible dans Netdata | Le graphique s'appelle `sensors...`, pas `temp...` | Chercher `sensors` dans « Search charts » |
| Un site affiche le contenu d'un autre | Port changé dans `docker-compose.yml` mais pas dans l'URL de la route du tunnel | Mettre à jour le port dans Published application routes |
