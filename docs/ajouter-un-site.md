# Ajouter un nouveau site/service — procédure complète

Runbook pour exposer un nouveau service Docker sur `*.maximelabatut.com` via Cloudflare Tunnel, avec accès fichiers en Samba.

Architecture de référence : chaque service = un conteneur web (port dédié sur le Pi) + un tunnel Cloudflare dédié + un sous-domaine public.

Toute la configuration (`docker-compose.yml`, contenu des sites) est versionnée sur [github.com/maximelabatut/maximelabatut](https://github.com/maximelabatut/maximelabatut). Seul `.env` (tokens Cloudflare) n'y est jamais poussé.

---

## Restauration après changement de carte SD

La procédure complète (rapide et manuelle) est dans **`restauration-carte-sd.md`** : après avoir flashé la carte avec Raspberry Pi Imager, une seule commande depuis le Mac (`~/Desktop/raspberrypi/restaurer-pi.sh`) envoie le `.env` et lance `restore.sh` (versionné dans le repo) sur le Pi. Ce script réinstalle le système, Docker, clone le repo, recalcule `DOCKER_GID`, configure Samba et le module Argon, puis lance les conteneurs.

Rappels propres au projet (détails dans cette doc) :
- Les tunnels Cloudflare, Access et le MFA ne dépendent pas de la carte : rien à refaire côté Cloudflare.
- Il faut un token par tunnel dans `.env` : `WWW`, `GAMEVAULT`, `WEB2`, `CONFIG`, `LOGS`, `NETDATA`, `UPTIME`. `DOCKER_GID` est recalculé à chaque installation (jamais restauré), sur sa propre ligne : si la dernière ligne du fichier n'a pas de retour à la ligne final, la valeur se colle au token précédent et le corrompt (`Provided Tunnel token is not valid`).
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
- `uptime-kuma/data/` n'est **pas versionné** (il contient le compte administrateur, le hash de son mot de passe et le canal ntfy) mais il est **sauvegardé sur le Mac** par `sauvegarder-pi.sh` (`~/Desktop/raspberrypi/uptime-kuma-data.tgz`, avec le `.env`) et **restauré automatiquement** par `restaurer-pi.sh` / `restore.sh` avant le premier lancement : après une restauration, le compte, les sondes et la notification ntfy sont déjà en place. Le dossier est créé par `restore.sh` pour qu'il appartienne à `maxime`.
- **Pourquoi pas un simple `cp` de `kuma.db`** : la base est en mode WAL. Le journal `kuma.db-wal` peut être plus gros que la base elle-même (1,1 Mo contre 380 Ko constatés) et contenir les écritures récentes. La sauvegarde utilise donc `sqlite3 .backup`, qui produit un instantané cohérent même pendant que Uptime Kuma écrit, plus `db-config.json` (sans lui, Uptime Kuma redemande le choix de la base de données). Le script vérifie `PRAGMA integrity_check` et le nombre de sondes avant de remplacer l'ancienne sauvegarde.
- **`sudo` demande un mot de passe sur ce Pi** (il n'est pas en `NOPASSWD`). Les scripts distants (`sauvegarder-pi.sh`, `restore.sh`) sont donc exécutés avec un terminal (`ssh -t`) pour que `sudo` puisse le demander, et `restore.sh` maintient l'autorisation (`sudo -v` puis boucle `sudo -n true`) pour ne pas le redemander après les mises à jour. Conséquence : ces scripts ne peuvent pas tourner sans surveillance (tâche planifiée) tant que `sudo` n'est pas passwordless ou qu'aucune clé SSH n'est en place.
- Penser à relancer `sauvegarder-pi.sh` après avoir modifié les sondes ou la notification.
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

Application personnelle : une page HTML (`GameVault.html`), un petit serveur Python (`rss_proxy_server.py`, bibliothèque standard uniquement, port 8787, qui relaie les requêtes du navigateur et gère le catalogue et la wishlist) et une base SQLite (`catalog.db`). Source de référence : le dossier `~/Desktop/raspberrypi/GameVault` du Mac, lancé en local par `run.bat` (Windows).

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
3. Depuis le Mac, copier le code et la base (via le partage `/Volumes/docker`) :
```bash
mkdir -p /Volumes/docker/gamevault/app /Volumes/docker/gamevault/data
cd ~/Desktop/raspberrypi/GameVault
cp GameVault.html rss_proxy_server.py logo.png logo.ico /Volumes/docker/gamevault/app/
cp catalog.db /Volumes/docker/gamevault/data/catalog.db
```
4. Sur le Pi : `docker compose up -d gamevault www-status`, puis `docker compose logs gamevault | tail`.
5. Uptime Kuma : modifier la sonde GameVault et mettre l'URL `http://gamevault:8787/` (voir ci-dessous).
6. Relancer `~/Desktop/raspberrypi/sauvegarder-pi.sh` pour produire `gamevault-data.tgz`.

### Mettre à jour le code

Modifier les fichiers dans `~/Desktop/raspberrypi/GameVault`, les recopier dans `/Volumes/docker/gamevault/app/`, puis `docker compose restart gamevault` sur le Pi.

### Surveillance et statut public

- **Page d'accueil (www)** : la carte GameVault reste affichée. `www-status` ne peut plus tester l'URL publique (Cloudflare Access répondrait par sa page de connexion) : il teste l'application par son nom sur le réseau Docker, `http://gamevault:8787/` (`www/status.sh`).
- **Uptime Kuma** : même raison, remplacer l'URL de la sonde `gamevault.maximelabatut.com` par `http://gamevault:8787/` (les services d'un même `docker-compose.yml` partagent un réseau et se joignent par leur nom ; `host.docker.internal` ne convient pas, le port n'étant publié que sur `127.0.0.1`).

### Sauvegarde et restauration

- `sauvegarder-pi.sh` prend un instantané cohérent de la base (`sqlite3 .backup`), le vérifie (`PRAGMA integrity_check`, nombre de jeux) et l'enregistre dans `~/Desktop/raspberrypi/gamevault-data.tgz` (environ 5 Mo pour ~2 500 jeux), avec le `.env` et les données d'Uptime Kuma. Version précédente en `.prev`. Le fichier `catalog.db` du dossier `GameVault` du Mac n'est **jamais écrasé** : il reste la copie de départ.
- `restaurer-pi.sh` envoie le **code** (depuis le dossier `GameVault` du Mac) et `gamevault-data.tgz` ; `restore.sh` les déploie dans `~/docker/gamevault/app` et `~/docker/gamevault/data` avant le premier lancement.
- Si le dossier `GameVault` du Mac est perdu, le code n'est nulle part ailleurs (il n'est pas dans le dépôt du homelab) : le versionner dans un dépôt **privé** est recommandé (le dépôt `github.com/maximelabatut/gamevault` est actuellement public).

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

### Tester

Ouvrir le site en navigation privée : email, code reçu par mail, code de l'application d'authentification, puis le service. Si le site s'affiche sans aucune demande de connexion, la destination n'est pas rattachée à l'application Access.

---

## 0. Convention à respecter

- Dossier du service : `~/docker/<nom-service>/html`
- Port local : le prochain port libre (8080 = www, 8081 = gamevault, 8082 = web2, 8083 = dashboard (`config.`), 8084 = Dozzle (`logs.`), 8085 = Uptime Kuma (`uptime.`), 19999 = Netdata (réseau `host`), → 8086 pour le suivant, etc.)
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

Ajouter le nouveau service (et son tunnel) dans `APPS` et `DESCRIPTIONS` de `dashboard/html/index.html` (cf section « Ajouter une application au dashboard »). Si le sous-domaine donne accès à quelque chose de sensible (outil d'admin, métriques, logs), l'ajouter aussi aux destinations de l'application Cloudflare Access **avant** de l'utiliser.

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
