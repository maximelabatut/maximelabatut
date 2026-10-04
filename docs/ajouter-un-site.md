# Ajouter un nouveau site/service — procédure complète

Runbook pour exposer un nouveau service Docker sur `*.maximelabatut.com` via Cloudflare Tunnel, avec accès fichiers en Samba.

Architecture de référence : chaque service = un conteneur web (port dédié sur le Pi) + un tunnel Cloudflare dédié + un sous-domaine public.

Toute la configuration (`docker-compose.yml`, contenu des sites) est versionnée sur [github.com/maximelabatut/maximelabatut](https://github.com/maximelabatut/maximelabatut). Seul `.env` (tokens Cloudflare) n'y est jamais poussé.

> Cette documentation est **générique** : elle décrit la méthode, pas le détail de l'installation (ports internes, applications sensibles, procédures de secours), conservé dans une documentation privée.

---

## Restauration après changement de carte SD

La procédure complète (rapide et manuelle) est dans **`restauration-carte-sd.md`** : après avoir flashé la carte avec Raspberry Pi Imager, une seule commande depuis le Mac (`mac/restaurer-pi.sh`) déchiffre la dernière sauvegarde (archive chiffrée sur GitHub), envoie le `.env` et les données, et lance `restore.sh` (versionné dans le repo) sur le Pi. Ce script réinstalle le système, Docker, clone le repo, recalcule `DOCKER_GID`, configure Samba et le module Argon, puis lance les conteneurs.

Rappels propres au projet (détails dans cette doc) :
- Les tunnels Cloudflare, Access et le MFA ne dépendent pas de la carte : rien à refaire côté Cloudflare.
- Il faut un token par tunnel dans `.env` (`CLOUDFLARE_TUNNEL_TOKEN_<APPLICATION>`, liste dans `.env.example`). `DOCKER_GID` est recalculé à chaque installation (jamais restauré), sur sa propre ligne : si la dernière ligne du fichier n'a pas de retour à la ligne final, la valeur se colle au token précédent et le corrompt (`Provided Tunnel token is not valid`).
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

SSH n'est atteignable que depuis le réseau local (aucun port n'est redirigé sur la box) et n'accepte que l'authentification par **clé** (ed25519, protégée par une phrase secrète) : mots de passe et connexion `root` désactivés. Fail2ban devient inutile (aucun mot de passe à deviner).

Réglages (`/etc/ssh/sshd_config.d/00-hardening.conf`) :
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

1. Poste d'administration : créer une clé dédiée (`ssh-keygen -t ed25519 -a 100 -C "<commentaire>" -f ~/.ssh/id_ed25519_<nom>`) avec une phrase secrète aléatoire générée par le gestionnaire de mots de passe.
2. Installer la clé publique : `ssh-copy-id -i ~/.ssh/id_ed25519_<nom>.pub <utilisateur>@<hôte>.local`.
3. **Avant** de couper les mots de passe, vérifier que la clé seule suffit : `ssh -o PreferredAuthentications=publickey -o PasswordAuthentication=no <utilisateur>@<hôte>.local 'echo clé OK'`.
4. Ouvrir une session sur le Pi et **la laisser ouverte** (porte de secours), y écrire `00-hardening.conf`, valider avec `sudo sshd -t`, relire la configuration **effective** avec `sudo sshd -T | grep -iE '^(passwordauthentication|permitrootlogin|pubkeyauthentication|authenticationmethods)'`, puis `sudo systemctl reload ssh` (reload, pas restart).
5. Dans un **nouveau** terminal : la connexion par clé doit réussir et `ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no <utilisateur>@<hôte>.local` doit répondre `Permission denied (publickey)`.

**Annuler** (depuis la session restée ouverte) : `sudo rm /etc/ssh/sshd_config.d/00-hardening.conf && sudo systemctl reload ssh`.

### Perte de la clé et restauration

- La clé devient le **seul** moyen d'entrer en SSH : en garder une copie (le fichier de clé, chiffré par sa phrase, et la phrase) **hors du poste**, dans le gestionnaire de mots de passe ou sur un support chiffré.
- Une carte fraîchement flashée a de nouveau l'authentification par mot de passe : refaire les étapes 2 à 5 après une restauration.

---

## Monitoring : dashboard, Netdata, Dozzle et Uptime Kuma

Quatre services complémentaires, tous derrière Cloudflare Access (cf section suivante) :

| URL | Service | Rôle |
|---|---|---|
| `config.maximelabatut.com` | Dashboard sur mesure (nginx + page HTML) | Vue d'ensemble : température CPU + courbe, CPU, RAM, stockage, et un tiroir par application (conteneur + tunnel, état, CPU, lien vers les logs) |
| `netdata.maximelabatut.com` | Netdata | Métriques détaillées avec historique (capteurs, réseau, disque, alertes) |
| `logs.maximelabatut.com` | Dozzle | Logs en direct de tous les conteneurs (lecture seule) — **service à la demande**, cf. « Dozzle à la demande » |
| `uptime.maximelabatut.com` | Uptime Kuma | Surveillance des sites toutes les minutes, alertes sur le téléphone via ntfy (cf section « Alertes ») |

### Comment ça marche

- **Netdata** collecte les métriques de la machine hôte et des conteneurs (accès en lecture à l'hôte et à Docker ; le groupe `docker` est renseigné par la variable `DOCKER_GID` du `.env`).
- **Dashboard** : `dashboard/html/index.html` (HTML + JavaScript, sans dépendance externe) interroge l'API de Netdata. Le conteneur nginx (`dashboard/nginx.conf`, réseau `host`) ne relaie que `GET /api/v1/data` et `GET /api/v1/charts`, avec un micro-cache de 3 s.
- La température vient du graphique Netdata `sensors.temperature_cpu_thermal-virtual-0_temp1_input`. La vitesse du ventilateur n'est pas exposée par le Pi : la page affiche une valeur **estimée** d'après la courbe Argon (< 55 °C arrêté, 55 °C = 30 %, 60 °C = 55 %, 65 °C = 100 %). La mémoire par conteneur n'est pas disponible (comptabilité mémoire des cgroups désactivée par défaut sur Raspberry Pi OS).
- Dans l'interface Netdata, les capteurs se trouvent en cherchant `sensors` (et non `temp`).

### Les tiroirs par application

Chaque application est un tiroir (`<details>`) regroupant son conteneur nginx et son tunnel Cloudflare. La page les répartit en **deux catégories**, via le champ `category` de la liste `APPS` (`'main'` ou `'tech'`) :

**Applications** (`main`)

| Tiroir | Conteneurs |
|---|---|
| Site principal | `www` + `www-status` + `cloudflared-www` |
| GameVault | `gamevault` (Python) + `cloudflared-gamevault` |
| Application privée | `<application>` + `cloudflared-<application>` |
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
- **Liens vers Dozzle** : Dozzle n'accepte que l'ID court du conteneur dans l'URL (`/container/<id>`), qui change à chaque recréation. Le conteneur `dashboard-sync` (image `docker:cli`, script `dashboard/sync.sh`) écrit `dashboard/data/containers.json` **à chaque événement Docker** (création, démarrage, arrêt, destruction, renommage ; ~2 s de délai) et au plus tard toutes les 300 s, au lieu d'interroger Docker toutes les 10 s (id, nom, image uniquement, jamais la commande ni l'environnement), servi par nginx sur `/containers.json`.

### Ajouter une application au dashboard

Dans `dashboard/html/index.html` :
1. Ajouter une entrée dans la liste `APPS` : `{ id, category: 'main' | 'tech', name, url, members: ['<app>', 'cloudflared-<app>'] }` (`main` pour une application, `tech` pour un outil de maintenance)
2. Ajouter une description par conteneur dans `DESCRIPTIONS` (sinon la page affiche le nom de l'image)

Sans l'étape 1, les conteneurs apparaissent quand même, dans le tiroir « Autres conteneurs ».

### Tunnels et routes

Un tunnel Cloudflare par sous-domaine, chacun avec son token dans `.env` (`CLOUDFLARE_TUNNEL_TOKEN_<APPLICATION>`) et son conteneur `cloudflared-<application>`. Chaque route (Published application routes) associe un hostname à `http://localhost:<port>`, le port étant celui publié par le conteneur dans `docker-compose.yml`.

### Modifier le dashboard

Éditer `dashboard/html/index.html` directement via le partage Samba (`/Volumes/docker/dashboard/html/`) : nginx le sert en lecture seule à chaud, un simple rechargement de la page suffit (si le navigateur garde l'ancienne version : `Cmd+Maj+R`). Une modification de `nginx.conf` demande `docker compose restart dashboard`, une modification de `sync.sh` demande `docker compose restart dashboard-sync`.

### Alertes : Uptime Kuma + ntfy

**Uptime Kuma** (`uptime.maximelabatut.com`, image `louislam/uptime-kuma:2`, base **SQLite**, données dans `uptime-kuma/data/`) surveille les sites et envoie une alerte sur le téléphone via **ntfy** (notifications push). Le conteneur déclare `extra_hosts: host.docker.internal:host-gateway` pour pouvoir sonder des services du Pi (ports en réseau `host`).

**Mise en place (déjà faite, à refaire après une restauration)**

1. Créer le tunnel `uptime` (Zero Trust → Networks → Tunnels) et récupérer son token → `CLOUDFLARE_TUNNEL_TOKEN_UPTIME` dans `.env`.
2. **Avant** de publier la route : ajouter `uptime.maximelabatut.com` aux destinations de l'application Cloudflare Access (sinon le premier visiteur pourrait créer le compte administrateur), puis ajouter la route `uptime.maximelabatut.com` → `http://localhost:<port>`.
3. `docker compose up -d`, puis ouvrir `https://uptime.maximelabatut.com` : choisir **SQLite**, créer le compte administrateur (mot de passe dans le gestionnaire de mots de passe).
4. ntfy : générer un nom de canal secret (`echo "homelab-$(openssl rand -hex 12)"`), installer l'application ntfy sur le téléphone et s'abonner au canal. Le nom du canal est le « mot de passe » : ne pas le partager ni le mettre dans git ou `.env` (Uptime Kuma ne lit pas ses réglages dans `.env` ; la notification est stockée dans sa base). Test indépendant depuis le Mac, sans laisser le canal dans l'historique :
   ```bash
   read -r -s -p "Canal ntfy : " T; echo
   curl -d "Test depuis le Mac" "https://ntfy.sh/$T"; echo
   unset T
   ```
5. Dans Uptime Kuma (menu du compte → **Paramètres → Notifications → Configurer une notification**) : type **Ntfy**, serveur `https://ntfy.sh`, le canal, priorité 4, cocher **Activé par défaut** et **Appliquer à toutes les sondes existantes**, puis **Tester**.
6. Ajouter les **sondes** (type HTTP(s), intervalle 60 s, nouvelles tentatives 2, soit une alerte après ~3 min) : `https://www.maximelabatut.com`, `https://gamevault.maximelabatut.com`, `https://web2.maximelabatut.com` (test de bout en bout, tunnel compris). Pour les outils derrière Access, les adresses publiques ne conviennent pas (Access répond avant le tunnel, la sonde resterait verte même tunnel tombé) : utiliser `http://host.docker.internal:<port>` pour les services en réseau `host`. Les services liés à `127.0.0.1` ne sont pas joignables depuis le conteneur.

**Test réel (validé le 3 oct. 2026)** : `docker compose stop web2` → au bout de ~3 min, notification d'erreur **502** (le tunnel répond mais `web2` est arrêté) ; `docker compose start web2` → notification de retour **200**.

**Limites et restauration**
- Si le **Pi entier** tombe, Uptime Kuma tombe avec lui : aucune alerte ne part. Il faudrait une surveillance externe (heartbeat vers un service qui alerte en l'absence de signal).
- `uptime-kuma/data/` n'est **pas versionné** (il contient le compte administrateur, le hash de son mot de passe et le canal ntfy) mais il est **sauvegardé chaque jour** dans l'archive chiffrée du dépôt privé de sauvegardes (avec le `.env`) et **restauré automatiquement** par `restaurer-pi.sh` / `restore.sh` avant le premier lancement : après une restauration, le compte, les sondes et la notification ntfy sont déjà en place. Le dossier est créé par `restore.sh` pour qu'il appartienne à `maxime`.
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
| `netdata/netdata.conf` | `[plugins] scripts.d, otel, netflow, network-viewer, systemd-journal, systemd-units, ioping, perf, charts.d, python.d, tc, statsd = no` | extensions inutilisées désactivées (4 oct. 2026) : 14 → 4 processus, ~345 → ~205 Mo de RAM. **À conserver activées : `proc`, `cgroups`, `diskspace`, `go.d` et `debugfs`** (cette dernière fournit la température du CPU lue par le dashboard) |
| `netdata/go.d/docker.conf` | job `local`, `update_every: 10`, `collect_container_size: no` | collecteur Docker ralenti (voir ci-dessous). Le nom `local` doit rester : le dashboard lit les graphiques `docker_local.*` |

Après modification d'un de ces fichiers : `docker restart netdata`. Juste après un (re)démarrage, Netdata journalise une rafale d'une trentaine d'avertissements `SPAWN SERVER ... cgroup-network-helper.sh` pendant ~2 s (son assistant réseau échoue une fois par conteneur en réseau `host`, qui n'a pas d'interface propre) : normal, il n'y en a plus ensuite.

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
Pour trouver un coupable : comparer avant/après avoir arrêté le conteneur suspect (`docker compose stop <service>`), puis le relancer. Avant de mesurer un réglage Netdata, vérifier qu'il est bien appliqué : le `update_every` des graphiques `docker_local.*` doit valoir 10 dans `http://localhost:<port de Netdata>/api/v1/charts` (une première mesure avait été faite par erreur sur l'ancien état, le conteneur n'ayant pas été recréé). Juste après un redémarrage, Netdata consomme davantage pendant quelques minutes (le ML réentraîne ses modèles) : attendre avant de mesurer. Dans le dashboard, les états de conteneurs sont lus sur une fenêtre de 20 s (`latest(chart, 20)`) pour tolérer cette collecte à 10 s.

Le dashboard met aussi en pause son rafraîchissement quand l'onglet est caché (`document.hidden`) : un aperçu ouvert dans un onglet en arrière-plan ne s'actualise donc pas.

### Dozzle à la demande

Dozzle (lecteur de logs) et son tunnel `cloudflared-logs` ne tournent **que lorsqu'on en a besoin** (profil Compose `logs`). Gain : ~85 Mo de RAM et ~1,3 % de cœur en moyenne, et surtout **un outil d'administration de moins** exposé en permanence : il n'existe que pendant la lecture des logs.

```bash
bash ~/docker/pi/logs.sh on       # démarre Dozzle et son tunnel (https://logs.<domaine>, derrière Access)
bash ~/docker/pi/logs.sh off      # les arrête
bash ~/docker/pi/logs.sh status
```
- Sans Dozzle, les logs restent lisibles en SSH : `docker compose logs <service>`.
- Le dashboard affiche alors le tiroir « Logs (Dozzle) » en gris (« à la demande ») et désactive les liens vers les logs.
- **`docker compose up -d` (et donc une restauration) ne démarre pas Dozzle**, et peut l'arrêter s'il tourne. Après un redéploiement : `pi/logs.sh on` si besoin. Pour tout démarrer d'un coup : `docker compose --profile logs up -d`.
- Un conteneur arrêté à la main reste arrêté après un redémarrage du Pi (`restart: unless-stopped`).
- **Bouton dans le dashboard** : le tiroir « Logs (Dozzle) » propose « Démarrer / Arrêter Dozzle ». **Arrêt automatique 2 h après le démarrage**, quel que soit le moyen de démarrage.
- Un petit service dédié (`logs-control`, Python standard) est le seul à pouvoir agir, et **uniquement sur ces deux conteneurs** (noms fixés dans le code, aucune valeur de requête dans les appels Docker). Il est durci (utilisateur non root, système de fichiers en lecture seule, aucune capacité Linux) et protégé contre les requêtes forgées (en-tête de contrôle obligatoire, une écriture toutes les 2 s). Tests : `python3 dashboard/logs-control/test_control.py` (faux démon Docker).
- Les conteneurs doivent exister pour que le bouton marche : `restore.sh` les crée sans les démarrer (`docker compose --profile logs up --no-start dozzle cloudflared-logs`).
- Cloudflare Access répond toujours par sa redirection, même Dozzle arrêté : le contrôle d'exposition reste valable.

### Optimisations du 4 octobre 2026

Analyse faite avec les données de Netdata (historique ~20 h) et de Dozzle/`docker logs` : le Pi est calme (charge ~0,1, ~46 °C), mais **`dockerd` et `containerd` consomment ensemble plus de CPU (~56 % d'un cœur en moyenne) que les 18 conteneurs réunis (~11 %)**. Mesures et actions :

| Action | Avant | Après |
|---|---|---|
| Extensions Netdata inutiles désactivées | 14 processus, 345 Mo ; `scripts.d` journalisait ~1 270 erreurs/jour (dossier inexistant) | 4 processus, ~205 Mo |
| `dashboard-sync` piloté par les événements Docker | `docker ps -a` toutes les 10 s (8 640 appels/jour) | un appel par changement de conteneur |
| `www-status` | un test toutes les 30 s | un test toutes les 60 s |
| Rotation des logs Docker (`x-logging` du compose : 3 × 10 Mo par conteneur) et logs d'accès du dashboard coupés (`access_log off`) | aucune rotation ; ~3 Mo/jour de logs d'accès inutiles pour le dashboard | taille des logs bornée |
| Dozzle à la demande | toujours en marche (~85 Mo avec son tunnel) | arrêté sauf lecture de logs (bouton du dashboard ou `pi/logs.sh on / off`, arrêt automatique après 2 h) |
| Nettoyage Docker | 633 Mo de cache de build + 2 images inutilisées | 0 ; disque 26 % → 25 % |

À savoir :
- **La mémoire par conteneur n'est pas disponible** (cgroups mémoire désactivés) : elle se calcule à partir des processus (`/proc/<pid>/status`, champ `VmRSS`, rattaché au conteneur par `/proc/<pid>/cgroup`).
- Nettoyage périodique : `docker builder prune -f` (cache de build) et `docker image prune` ; `docker system df` montre ce qui est récupérable.
- Pistes non appliquées, à ne retenir que si le besoin apparaît : regrouper les 8 `cloudflared` en un seul tunnel (−7 conteneurs, ~265 Mo, ~3 % de cœur, mais perte de l'isolation « un tunnel par application »), activer les cgroups mémoire, passer la collecte Docker de Netdata à 30 s.

### Température du Pi : valeurs de référence

| Température | Interprétation |
|---|---|
| < 60 °C | zone confortable (45-50 °C au repos est normal) |
| 60 à 70 °C | charge soutenue, acceptable |
| 70 à 80 °C | à surveiller |
| ≥ 80 °C | le processeur ralentit (throttling) |
| 85 °C | limite dure |

Vérifier qu'il n'y a jamais eu de ralentissement ni de sous-tension : `vcgencmd get_throttled` (`throttled=0x0` = tout va bien).

### Exposition des outils d'administration

Les ports publiés par un outil d'administration (logs, métriques, surveillance) sont liés à `127.0.0.1` quand c'est possible : seul le tunnel (réseau `host`) y accède, derrière Cloudflare Access. Ne jamais publier ces outils sans authentification (cf. « Sécuriser avec Cloudflare Access + MFA »).

---

## Applications personnelles (code dans un dépôt privé)

Certaines applications (Python, SQLite…) ont leur code dans un **dépôt GitHub privé** et leurs données hors git. Principes communs :

| Élément | Emplacement | Versionné dans le dépôt du homelab ? |
|---|---|---|
| Code | `~/docker/<application>/app/` (clone du dépôt privé) | non (`.gitignore`) |
| Données (base SQLite…) | `~/docker/<application>/data/` | non (`.gitignore`), incluses dans l'archive de sauvegarde chiffrée |

- **Image** officielle (`python:3.12-slim`, …) qui monte le code ; port publié sur `127.0.0.1` ; tunnel dédié.
- **Accès : toujours derrière Cloudflare Access + MFA.** Une application sans authentification propre ne doit jamais être publiée directement : ajouter l'adresse aux destinations Access **avant** de démarrer le conteneur, car la route de tunnel serait sinon publique dès le démarrage.
- **Surveillance** : Cloudflare Access répond avant le tunnel, donc les sondes de l'URL publique restent vertes même tunnel tombé : sonder le conteneur par son nom sur le réseau Docker (`http://<conteneur>:<port>/`).
- **Mise à jour du code** : pousser dans le dépôt privé, puis sur le Pi `git -C ~/docker/<application>/app pull` et `docker compose restart <application>` (ou `up -d --build` pour une image construite sur place).

### Clé de déploiement (lecture seule)

Le dépôt étant privé, le Pi s'y authentifie avec une **clé de déploiement** : une clé SSH dédiée à ce seul dépôt, en **lecture seule**, qui n'expire pas (une clé par dépôt : GitHub refuse la même clé sur deux dépôts).

- **Création (sur le Pi)** : `ssh-keygen -t ed25519 -N "" -C "<application>-deploy@homelab" -f ~/.ssh/<application>_deploy` (clé privée en `600`, incluse dans l'archive chiffrée quotidienne ; **ne jamais la versionner**).
- **Enregistrement** : GitHub → dépôt → Settings → Deploy keys → Add deploy key, avec la clé publique. ⚠️ **Ne pas cocher « Allow write access »** : cette option ne peut pas être modifiée ensuite (supprimer et recréer la clé).
- **Sur le Pi** : un bloc `Host github-<application>` dans `~/.ssh/config` (`IdentityFile`, `IdentitiesOnly yes`) puis `git clone git@github-<application>:<propriétaire>/<dépôt>.git`.
- **Tester qu'elle est bien en lecture seule** : un `git push` vers une **branche jetable** (jamais `main`) doit être refusé avec `The key you are authenticating with has been marked as read only`.
- **Empreintes de `github.com`** : en cas d'avertissement `REMOTE HOST IDENTIFICATION HAS CHANGED`, ne rien contourner. Comparer les empreintes présentées (`ssh-keyscan github.com | ssh-keygen -lf -`) à celles publiées par GitHub (`curl -s https://api.github.com/meta`, champ `ssh_key_fingerprints`) ; en cas de différence, s'arrêter.

---

## Sauvegarde automatique (chiffrée, sur GitHub)

Le **Pi sauvegarde lui-même**, chaque jour, vers un dépôt GitHub **privé** dédié : le poste d'administration peut être éteint, absent ou remplacé. Les archives sont **chiffrées avant l'envoi** avec [`age`](https://age-encryption.org/) (clé asymétrique) : GitHub ne voit que des blocs illisibles, et le Pi ne détient que la clé *publique* de chiffrement.

| Élément | Rôle |
|---|---|
| Timer `systemd` + script exécuté en root | une sauvegarde par jour, rattrapée au démarrage si le Pi était éteint |
| Dépôt GitHub privé de sauvegardes | un commit unique contenant les 30 dernières archives (l'historique est réécrit à chaque envoi, donc les anciennes archives disparaissent réellement) |
| Clé de déchiffrement (privée) | **hors du Pi**, protégée par une phrase secrète, avec une copie hors du poste |

**Contenu d'une archive** : le `.env`, les bases de données des applications, les clés de déploiement, la configuration de la sauvegarde et un résumé sans secret. Un seul fichier, une seule clé pour tout restaurer.

### Principe d'une exécution

1. Instantanés cohérents des bases (`sqlite3 .backup`, qui tient compte du journal WAL) et contrôle d'intégrité ; arrêt immédiat si une base est corrompue.
2. Copie du `.env` (arrêt s'il n'y a aucun token valide) et des clés de déploiement.
3. Archive fabriquée **en mémoire** puis chiffrée à la volée : aucun secret n'est écrit en clair sur la carte SD.
4. Envoi vers GitHub, puis vérification que le dépôt a bien reçu le commit. En cas d'échec avant l'envoi, **rien n'est remplacé**.
5. Contrôle d'exposition (cf. « Contrôle d'accès »).

Suivi : `journalctl -u homelab-backup -n 30 --no-pager` ; prochaine exécution : `systemctl list-timers homelab-backup` ; forcer : `sudo systemctl start homelab-backup`. Une alerte peut être envoyée par un moniteur Uptime Kuma de type **Push** si aucune sauvegarde n'a réussi depuis 25 h.

### Tester la restauration (sans Pi)

`mac/restaurer-pi.sh --verifier` récupère la dernière archive, la déchiffre et contrôle qu'elle est restaurable (fraîcheur, contenu, tokens, intégrité des bases, clés de déploiement joignant leurs dépôts). Rien n'est écrit ailleurs que dans un dossier temporaire du poste. **À lancer chaque mois** : une sauvegarde jamais testée n'est pas une sauvegarde.

### À connaître

- **La clé de déchiffrement est irremplaçable** : perdue, les sauvegardes sont illisibles pour toujours ; compromise avec l'accès au dépôt, elles sont toutes lisibles. En garder une copie hors du poste et activer la double authentification du compte GitHub.
- Si la clé est remplacée, les archives existantes restent chiffrées pour l'ancienne : la conserver le temps de la rotation.
- La sauvegarde dépend de GitHub (disponibilité, compte). Un envoi qui échoue ne détruit rien ; il est rejoué le lendemain.

### Installer `age` sur le Mac (nécessaire pour tester et restaurer, pas pour sauvegarder)

Le Pi chiffre avec son propre `age` (installé par `install-backup.sh`). Le Mac n'en a besoin que pour **déchiffrer** : test d'une archive, restauration.

- Cas général : `brew install age`.
- **macOS 13 (Intel) : `brew install age` échoue.** Homebrew n'a pas de binaire précompilé pour cette version (Tier 3), compile `age` depuis les sources, et son bac à sable coupe le réseau : le build s'arrête sur `dial tcp: lookup proxy.golang.org: no such host` alors que le réseau fonctionne. Relancer ne change rien. Go est en revanche installé par cette tentative ; compiler `age` directement, hors du bac à sable (modules vérifiés par la base de checksums de Go) :
  ```bash
  go install filippo.io/age/cmd/age@v1.3.2
  echo 'export PATH="$HOME/go/bin:$PATH"' >> ~/.zshrc && source ~/.zshrc
  age --version
  ```
- **Vérifier que la clé fonctionne** (ne touche à rien de réel, `age` demande la phrase secrète) :
  ```bash
  echo "test sauvegarde" | age -R ~/.ssh/id_ed25519_<nom>.pub -o /tmp/test.age && age -d -i ~/.ssh/id_ed25519_<nom> /tmp/test.age; rm -f /tmp/test.age
  ```
  Doit afficher `test sauvegarde`.

---

## Page d'accueil publique (www.maximelabatut.com)

Vitrine du homelab : `www/html/index.html`, une page statique sans dépendance externe (fond crème, accents terracotta, polices système). Sections : accueil avec pastille d'état en direct, cartes des applications (GameVault, Web2) avec statut, schéma du trajet d'une visite (visiteur → Cloudflare → tunnel → Raspberry Pi → Docker, vertical sur mobile), technologies utilisées, contact (GitHub). Les animations respectent `prefers-reduced-motion`.

### Statut en direct

Le conteneur `www-status` (image `curlimages/curl`, script `www/status.sh`, `user: root`) teste toutes les 60 s (30 s avant le 4 oct. 2026) les **URL publiques** des trois sites (`www`, `gamevault`, `web2`, donc tunnel et Cloudflare compris, un site est « en ligne » s'il répond `200`) et écrit `www/html/data/status.json` :

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

⚠️ Les outils de supervision donnent accès à des informations sensibles. **Ne jamais exposer ces sous-domaines sans Access.** Dozzle reste en lecture seule : laisser désactivés « Démarrer/arrêter » et « Shell » dans son assistant de configuration.

### Application Access (Zero Trust → Access controls → Applications → Add an application)

1. Type **Self-hosted and private**, sous-onglet **Public DNS**
2. Destinations : `config.maximelabatut.com`, `logs.maximelabatut.com`, `netdata.maximelabatut.com`, `uptime.maximelabatut.com` (tout nouveau sous-domaine sensible doit y être ajouté)
3. Policy : **Allow**, règle **Emails** = ton adresse (ex. policy « Moi uniquement »)
4. Authentication : laisser « Accept all available identity providers » (One-time PIN par email)
5. MFA : **Customize MFA settings** → Authenticator application, durée 24 h

### Enrôler l'authentificateur (une seule fois)

L'enrôlement MFA passe par l'**App Launcher**, qui doit être activé (Access controls → Access settings → App Launcher, avec la même policy « Moi uniquement » rattachée). Sans ça, le bouton « Setup MFA » renvoie sur une page « Welcome! Please contact your administrator… » et la page « No authentication methods set up » revient en boucle.

Lien direct d'enrôlement : `https://<équipe>.cloudflareaccess.com/AddMfaDevice` (email, code reçu par mail, puis scan du QR code et saisie du code à 6 chiffres jusqu'à validation).

Après l'enrôlement, Cloudflare peut te renvoyer sur la page d'accueil de l'organisation : retaper simplement l'URL du site voulu.

### Contrôle d'accès (verifier-acces.sh)

`pi/verifier-acces.sh` (installé sur le Pi sous `/usr/local/sbin/homelab-check-access`) vérifie, **sans être connecté et par le chemin public** (DNS puis Cloudflare, comme n'importe quel visiteur), que chaque sous-domaine est protégé par Access (ou public) comme prévu. Une application derrière Access répond **toujours** par un `302` vers `*.cloudflareaccess.com`, même si son conteneur est arrêté : toute autre réponse (200, 5xx, redirection ailleurs) veut dire qu'Access ne l'intercepte pas, donc une **exposition**.

| Sous-domaines | Attendu |
|---|---|
| `www`, `web2` | publics (HTTP 200) |
| tous les autres | derrière Access (302 vers `cloudflareaccess.com`) |

- Lancement manuel : `bash ~/docker/pi/verifier-acces.sh` (tableau complet ; code de sortie 0 = conforme, 1 = anomalie, 2 = pas de réseau). `--quiet` n'affiche que les anomalies.
- **À chaque sauvegarde (une fois par jour)**, `homelab-backup` le lance en dernier : en cas d'anomalie, ligne `EXPOSITION DÉTECTÉE` dans `journalctl -u homelab-backup` et, si le moniteur Push d'Uptime Kuma est configuré, alerte ntfy (la sauvegarde elle-même est déjà faite).
- **Règle** : toute nouvelle application ajoutée au `docker-compose.yml` doit être ajoutée aux listes `PUBLIC_HOSTS` / `PROTECTED_HOSTS` de `pi/verifier-acces.sh` (puis `sudo bash pi/install-backup.sh` pour recopier la version installée), sinon elle n'est pas contrôlée.
- Pourquoi ce contrôle : l'oubli de l'étape « ajouter l'adresse aux destinations Access » ne se voit pas à l'usage, puisque l'application fonctionne quand même.

### Tester

Ouvrir le site en navigation privée : email, code reçu par mail, code de l'application d'authentification, puis le service. Si le site s'affiche sans aucune demande de connexion, la destination n'est pas rattachée à l'application Access.

---

## 0. Convention à respecter

- Dossier du service : `~/docker/<nom-service>/html`
- Port local : le prochain port libre (voir les ports déjà publiés dans `docker-compose.yml`)
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
| « Statut du serveur indisponible pour le moment » sur la page d'accueil | `status.json` absent, périmé (> 3 min) ou non servi : `www-status` arrêté, ou `www` jamais recréé avec le bon montage (404 sur `/data/status.json`) | `docker compose up -d --force-recreate www www-status`, puis `cat www/html/data/status.json` et `curl -s http://localhost:<port de www>/data/status.json` |
| `"www":false` ponctuel dans `status.json` | Test réalisé pendant le redémarrage de `www` | Transitoire : le cycle suivant (60 s) remet à `true` |
| Conteneur affiché dans « Autres conteneurs » avec « Image : ... » | Absent de `APPS` / `DESCRIPTIONS` dans le dashboard | Ajouter le conteneur à un tiroir de `dashboard/html/index.html` |
| Dozzle « Conteneur non trouvé » depuis un lien du dashboard | Le lien utilise l'ID du conteneur, qui change quand il est recréé ; `containers.json` n'est pas encore à jour, ou `dashboard-sync` est arrêté | Attendre 10 s et recharger ; vérifier `docker compose ps` pour `dashboard-sync` |
| Noms de conteneurs non cliquables dans le dashboard | `/containers.json` absent (`dashboard-sync` jamais lancé ou dossier `dashboard/data` manquant) | `docker compose up -d`, vérifier que `~/docker/dashboard/data/containers.json` existe |
| Aucune température visible dans Netdata | Le graphique s'appelle `sensors...`, pas `temp...` | Chercher `sensors` dans « Search charts » |
| `brew install age` : `lookup proxy.golang.org: no such host` (macOS 13) | Pas de binaire précompilé : Homebrew compile `age` dans un bac à sable sans réseau. Le réseau, lui, fonctionne | `go install filippo.io/age/cmd/age@v1.3.2` (cf. « Installer `age` sur le Mac ») |
| Un site affiche le contenu d'un autre | Port changé dans `docker-compose.yml` mais pas dans l'URL de la route du tunnel | Mettre à jour le port dans Published application routes |
