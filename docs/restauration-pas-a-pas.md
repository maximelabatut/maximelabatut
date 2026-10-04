# Restauration complète pas à pas (carte SD vierge)

Ce document découpe la restauration en **19 tâches**. Pour chacune : qui agit, combien de temps, l'objectif, les commandes, le résultat attendu et quoi faire si ça coince. Le résumé général et le dépannage sont dans [`restauration-carte-sd.md`](restauration-carte-sd.md) ; le fonctionnement de la sauvegarde est dans [`ajouter-un-site.md`](ajouter-un-site.md) (section « Sauvegarde automatique »).

> **Les durées sont des estimations** (ordres de grandeur pour un Raspberry Pi 4, plus les « 20 à 30 minutes » du script). Aucune restauration complète n'a encore été chronométrée : à confirmer lors de la première répétition sur une carte de rechange.

## Vue d'ensemble

**Légende** : 🤖 autonome · 🧑 action de ta part · 🤝 semi-autonome (le script attend une saisie).

### Phase 1 : préparer la carte (~10 min)

| # | Tâche | Qui | Assistance demandée | Durée |
|---|---|---|---|---|
| [1](#t1) | Flasher la carte SD | 🧑 | Réglages dans Imager | ~5 min |
| [2](#t2) | Démarrer le Pi | 🤖 | Aucune (attendre) | ~2 à 3 min |

### Phase 2 : le script de restauration (~25 à 35 min, ~3 min de présence)

| # | Tâche | Qui | Assistance demandée | Durée |
|---|---|---|---|---|
| [3](#t3) | Lancer le script, récupérer l'archive | 🤝 | Identifiants GitHub (ou téléchargement de l'archive) | ~1 à 2 min |
| [4](#t4) | Déchiffrer l'archive | 🤝 | Phrase secrète de la clé SSH | ~10 s |
| [5](#t5) | Connexion SSH, envoi des secrets et des données | 🤝 | Mot de passe du Pi | ~30 s |
| [6](#t6) | Droits `sudo` | 🤝 | Mot de passe du Pi | immédiat |
| [7](#t7) | Mise à jour du système | 🤖 | Aucune | ~5 à 10 min |
| [8](#t8) | Installation de Docker | 🤖 | Aucune | ~2 à 3 min |
| [9](#t9) | Dépôts GitHub, bases de données, `.env` | 🤖 | Aucune | ~1 à 2 min |
| [10](#t10) | Sauvegarde quotidienne | 🤖 | Aucune | ~1 min |
| [11](#t11) | Samba | 🤝 | **Choisir le mot de passe Samba**, au milieu du script | ~1 min + attente |
| [12](#t12) | Module Argon (ventilateur) | 🤖 | Aucune | ~1 à 2 min |
| [13](#t13) | Conteneurs | 🤖 | Aucune | ~5 à 10 min |
| [14](#t14) | Redémarrage | 🤖 | Aucune | ~2 min |

### Phase 3 : après le redémarrage (~15 min)

| # | Tâche | Qui | Assistance demandée | Durée |
|---|---|---|---|---|
| [15](#t15) | Homewatch : première connexion | 🧑 | Identifiants du compte caméra + code de vérification | ~3 min |
| [16](#t16) | Réappliquer le durcissement SSH | 🧑 | Mot de passe du Pi, phrase de la clé | ~5 min |
| [17](#t17) | Vérifier les services | 🧑 | Authentification Cloudflare Access | ~5 min |
| [18](#t18) | Retrouver le partage Samba | 🧑 | Mot de passe Samba | ~1 min |
| [19](#t19) | Contrôler la sauvegarde quotidienne | 🧑 | Un coup d'œil | ~1 min |

**Total : environ 50 à 60 minutes** jusqu'à un homelab complet, dont **15 à 20 minutes de présence active** (flash, début du script plus saisie Samba, phase 3). Rien à refaire côté Cloudflare ni dans Uptime Kuma : tunnels, Access, MFA, sondes, base GameVault et configuration de la sauvegarde reviennent d'eux-mêmes.

---

## Avant de commencer (prérequis)

À avoir sous la main **avant** de flasher la carte :

| Quoi | Pourquoi | Où |
|---|---|---|
| Accès à ton **compte GitHub** (avec double authentification) | télécharger l'archive chiffrée du dépôt privé `maximelabatut-backups` | navigateur |
| La clé SSH **`~/.ssh/id_ed25519_homelab`** (fichier) et sa **phrase secrète** | déchiffrer l'archive : sans elles, les sauvegardes sont illisibles pour toujours | gestionnaire de mots de passe (copie hors ligne conseillée) |
| `age`, `git`, `ssh`, `bash` sur le poste de restauration | déchiffrer l'archive et lancer le script | Mac : `age --version` ; si absent, cf. [« Installer `age` sur le Mac »](ajouter-un-site.md) (sur macOS 13, `brew install age` échoue : `go install filippo.io/age/cmd/age@v1.3.2`) |
| Le **mot de passe de l'utilisateur** `maxime` que tu choisiras dans Imager | SSH et `sudo` sur le Pi | à noter avant de flasher |
| Poste et Pi sur le **même réseau** | `maxime.local` ne se résout qu'en local | box / WiFi |
| Sur un poste neuf : fichier de clé remis dans `~/.ssh/id_ed25519_homelab` | le script le cherche à cet endroit | `chmod 600 ~/.ssh/id_ed25519_homelab` (ou `AGE_KEY_FILE=chemin` au lancement) |

Rien d'autre n'est nécessaire : le `.env`, les bases, les clés de déploiement et la configuration de la sauvegarde sont **dans l'archive**.

---

## Phase 1 : préparer la carte

<a id="t1"></a>
### 1. Flasher la carte SD

- **Qui / durée** : 🧑 · ~5 min
- **Objectif** : obtenir une carte avec un système Raspberry Pi OS Lite 64 bits, un utilisateur, SSH et le WiFi déjà configurés, pour que le Pi soit joignable sans écran.
- **Action** : Raspberry Pi Imager → **Raspberry Pi OS Lite (64-bit)** → ⚙️ (réglages) :
  - hostname `maxime`
  - utilisateur `maxime` + mot de passe (à noter : il servira aux tâches 5, 6 et 16)
  - SSH activé (authentification par mot de passe, le temps de la restauration)
  - WiFi (SSID, mot de passe, pays `FR`)
  - fuseau `Europe/Paris`
- **Résultat attendu** : écriture et vérification terminées sans erreur.
- **Si ça coince** : carte non reconnue → autre lecteur ou autre port USB ; réglages oubliés → refaire le flash, c'est plus rapide que de corriger sur le Pi.

<a id="t2"></a>
### 2. Démarrer le Pi

- **Qui / durée** : 🤖 · ~2 à 3 min
- **Objectif** : le Pi démarre, rejoint le WiFi et devient joignable sous le nom `maxime.local`.
- **Action** : insérer la carte, brancher l'alimentation, attendre. Contrôle depuis le Mac :
  ```bash
  ping -c 3 maxime.local
  ```
- **Résultat attendu** : des réponses (`64 bytes from ...`). Le premier démarrage est plus long que les suivants.
- **Si ça coince** : `cannot resolve maxime.local` → le Pi n'a pas rejoint le WiFi (attendre 2 min de plus, puis vérifier le SSID et le mot de passe saisis dans Imager, ou chercher le Pi dans l'interface de la box).

---

## Phase 2 : le script de restauration

Un seul lancement enchaîne les tâches 3 à 14 :

```bash
git clone https://github.com/maximelabatut/maximelabatut.git ~/homelab-restore
~/homelab-restore/mac/restaurer-pi.sh
```

Il peut être **relancé sans risque** s'il s'interrompt (clones, installations et copies sont idempotents).

<a id="t3"></a>
### 3. Lancer le script et récupérer l'archive

- **Qui / durée** : 🤝 · ~1 à 2 min
- **Objectif** : obtenir la dernière archive chiffrée `homelab-AAAA-MM-JJ.tar.gz.age` du dépôt privé de sauvegardes.
- **Action** : lancer le script (ci-dessus). Il vérifie que `age` est installé, puis clone le dépôt privé en HTTPS. GitHub demande alors un **nom d'utilisateur** et un **personal access token** (le mot de passe du compte n'est plus accepté) :
  1. GitHub → Settings → Developer settings → Fine-grained tokens → accès *lecture* au dépôt `maximelabatut-backups` seulement, expiration courte
  2. le coller à la place du mot de passe
- **Variante sans identifiants** (plus simple) : télécharger le fichier depuis la page GitHub du dépôt (compte connecté, bouton *Download*), puis :
  ```bash
  ~/homelab-restore/mac/restaurer-pi.sh ~/Downloads/homelab-AAAA-MM-JJ.tar.gz.age
  ```
- **Résultat attendu** : `Archive : homelab-AAAA-MM-JJ.tar.gz.age`. Les 30 derniers jours sont disponibles : en cas de doute sur la plus récente, prendre la précédente.
- **Si ça coince** : `age est requis` → installer `age` (cf. prérequis) ; `Clonage impossible` → identifiants refusés, utiliser la variante par téléchargement ; `Aucune archive` → le dépôt est vide ou la sauvegarde ne tourne plus (voir tâche 19 sur l'ancien Pi, s'il est accessible).

<a id="t4"></a>
### 4. Déchiffrer l'archive

- **Qui / durée** : 🤝 · ~10 s
- **Objectif** : ouvrir l'archive **sur le poste de restauration** (jamais sur le Pi), dans un dossier temporaire privé (`700`) supprimé en fin de script, pour en extraire les secrets à renvoyer.
- **Action** : le script utilise `~/.ssh/id_ed25519_homelab` (ou `AGE_KEY_FILE=...`) et `age` demande la **phrase secrète** de la clé. Elle n'est pas reprise du Trousseau.
- **Résultat attendu** : le résumé de la sauvegarde s'affiche, par exemple :
  ```
  Sauvegarde du homelab : 2026-10-04 16:48:37 (maxime)
  8 tokens Cloudflare, Uptime Kuma : 6 sondes, GameVault : 2539 jeux
  Clés de déploiement : gamevault-deploy-key homewatch-deploy-key
  ```
  Vérifier que les chiffres sont plausibles avant de continuer (Ctrl-C sinon).
- **Si ça coince** : `Déchiffrement impossible` → mauvaise phrase, ou fichier de clé qui n'est pas celui dont la partie publique a chiffré l'archive (une clé SSH remplacée depuis ne peut pas ouvrir les anciennes archives) ; archive incomplète → la retélécharger.

<a id="t5"></a>
### 5. Connexion SSH, envoi des secrets et des données

- **Qui / durée** : 🤝 · ~30 s
- **Objectif** : envoyer sur le Pi (dans `/tmp`) tout ce dont `restore.sh` a besoin : `.env`, bases de données, clés de déploiement, configuration de la sauvegarde.
- **Action** : le script oublie l'ancienne clé SSH du Pi (`ssh-keygen -R maxime.local`, elle change à chaque flash), ouvre **une** connexion partagée et demande le **mot de passe de l'utilisateur `maxime`** (celui d'Imager). Il envoie ensuite les fichiers par `scp` et télécharge la dernière version de `restore.sh` depuis le dépôt public.
- **Résultat attendu** : `uptime-kuma-data.tgz envoyé.`, `gamevault-data.tgz envoyé.`, `Clé de déploiement ... envoyée.`, `Configuration de la sauvegarde quotidienne envoyée.`
- **Si ça coince** : `Could not resolve hostname` → retour à la tâche 2 ; `Permission denied` → mauvais mot de passe (celui saisi dans Imager) ; `Pas de ... dans l'archive` → l'élément concerné sera à reconfigurer à la main (ce n'est pas bloquant pour le script).

<a id="t6"></a>
### 6. Droits `sudo`

- **Qui / durée** : 🤝 · immédiat
- **Objectif** : disposer des droits administrateur pendant toute la restauration. `sudo` demande un mot de passe sur ce Pi et l'oublie après 5 minutes ; `restore.sh` le saisit **une fois** puis maintient l'autorisation en arrière-plan.
- **Action** : saisir le **même mot de passe** quand `== Droits administrateur (mot de passe du Pi)` s'affiche.
- **Résultat attendu** : le script poursuit sans redemander.
- **Si ça coince** : mot de passe refusé → le ressaisir ; l'invite n'apparaît pas → le script est lancé sans terminal (il doit être exécuté par `restaurer-pi.sh`, qui ouvre la session avec `ssh -t`).

<a id="t7"></a>
### 7. Mise à jour du système

- **Qui / durée** : 🤖 · ~5 à 10 min
- **Objectif** : partir d'un système à jour avant d'installer les services.
- **Commandes exécutées** (étape `1/7`) :
  ```bash
  sudo apt-get update -y
  sudo DEBIAN_FRONTEND=noninteractive apt-get full-upgrade -y -o Dpkg::Options::=--force-confold
  sudo apt-get install -y locales-all git
  ```
- **Résultat attendu** : défilement de paquets, sans erreur. `locales-all` supprime les avertissements de langue en SSH.
- **Si ça coince** : erreur réseau (`Temporary failure resolving`) → le Pi a perdu le WiFi, relancer le script une fois la connexion rétablie.

<a id="t8"></a>
### 8. Installation de Docker

- **Qui / durée** : 🤖 · ~2 à 3 min
- **Objectif** : installer Docker et Compose, et autoriser `maxime` à les utiliser sans `sudo`.
- **Commandes exécutées** (étape `2/7`) :
  ```bash
  curl -fsSL https://get.docker.com | sudo sh
  sudo usermod -aG docker "$USER"
  ```
- **Résultat attendu** : `docker --version` répond à la fin du script.
- **Si ça coince** : `permission denied` sur Docker plus tard → se déconnecter puis se reconnecter (le groupe `docker` n'est pris en compte qu'à la nouvelle session ; le script utilise `sg docker` pour contourner).

<a id="t9"></a>
### 9. Dépôts GitHub, bases de données et `.env`

- **Qui / durée** : 🤖 · ~1 à 2 min
- **Objectif** : remettre en place le code, les données et les secrets, **avant** le premier lancement des conteneurs.
- **Ce que fait le script** (étapes `3/7` et `4/7`) :
  - clone du dépôt public dans `~/docker`
  - création des dossiers de données (`uptime-kuma/data`, `gamevault/data`, `homewatch/data`, ...) pour qu'ils appartiennent à `maxime`
  - pour GameVault et Homewatch : installation de la clé de déploiement (`~/.ssh/<nom>_deploy`, `600`), bloc `Host github-<nom>` dans `~/.ssh/config`, clone du dépôt **privé** (lecture seule) dans `<nom>/app`
  - extraction des bases : `uptime-kuma-data.tgz` et `gamevault-data.tgz`
  - `.env` copié depuis l'archive, `DOCKER_GID` **recalculé** (il change à chaque installation de Docker), droits `600`
- **Résultat attendu** : le script affiche les noms des variables du `.env` avec leur longueur : **8 tokens de 184 caractères** et `DOCKER_GID 3`. Aucune valeur n'est affichée.
- **Si ça coince** : `Clone impossible (clé non enregistrée dans les Deploy keys ...)` → la clé de déploiement n'est plus enregistrée côté GitHub (dépôt `gamevault` ou `homewatch` → Settings → Deploy keys : y rajouter la clé publique, lecture seule) ; `ATTENTION : le code de ... est absent` → même cause, le conteneur concerné ne se construira pas.

<a id="t10"></a>
### 10. Sauvegarde quotidienne

- **Qui / durée** : 🤖 · ~1 min
- **Objectif** : remettre en route la sauvegarde chiffrée vers GitHub, **sans rien reconfigurer** : les clés viennent de l'archive.
- **Commandes exécutées** (dans l'étape `3/7`) :
  ```bash
  sudo install -d -m 700 -o root -g root /etc/homelab-backup
  sudo tar xzf /tmp/homelab-backup-config.tgz -C /etc/homelab-backup --no-same-owner
  sudo NOFIRST=1 bash ~/docker/pi/install-backup.sh
  ```
  `install-backup.sh` installe `age`, `sqlite3`, les scripts, le timer systemd, et régénère `known_hosts` à partir des clés officielles de GitHub (`api.github.com/meta`). Aucune question n'est posée, puisque la clé publique et la clé d'écriture sont déjà présentes.
- **Résultat attendu** : `Timer actif : ...` à la fin de l'installation.
- **Si ça coince** : si l'archive ne contenait pas `homelab-backup/` (très ancienne sauvegarde), l'installateur redemande la clé publique et recrée une clé d'écriture à enregistrer dans les Deploy keys du dépôt `maximelabatut-backups` (avec « Allow write access »).

<a id="t11"></a>
### 11. Samba

- **Qui / durée** : 🤝 · ~1 min + attente
- **Objectif** : retrouver le partage réseau `smb://maxime.local/docker` (le dossier `~/docker` du Pi, monté sur le Mac).
- **Action** : le script installe Samba, ajoute le partage `[docker]` à `/etc/samba/smb.conf`, puis demande **deux fois** le mot de passe Samba à choisir. **Ce moment arrive en cours de route** : reste devant le terminal, sinon le script attend simplement ta saisie.
- **Résultat attendu** : le service `smbd` actif, l'utilisateur Samba créé. Le mot de passe n'est jamais stocké : le noter dans le gestionnaire de mots de passe.
- **Si ça coince** : saisies différentes ou vides → le script redemande.

<a id="t12"></a>
### 12. Module Argon (ventilateur)

- **Qui / durée** : 🤖 · ~1 à 2 min
- **Objectif** : réinstaller le pilote du boîtier Argon ONE V2 et la courbe de ventilation du dépôt (`argon/argononed.conf` : 55 °C = 30 %, 60 °C = 55 %, 65 °C = 100 %).
- **Commandes exécutées** (étape `6/7`) :
  ```bash
  curl -fsSL https://download.argon40.com/argon1.sh | bash
  sudo cp ~/docker/argon/argononed.conf /etc/argononed.conf
  ```
- **Résultat attendu** : installation sans erreur ; le ventilateur est pris en compte après le redémarrage (tâche 14).
- **Si ça coince** : le site d'Argon injoignable → relancer le script plus tard, ou exécuter ces deux commandes à la main ; le reste du homelab n'en dépend pas.

<a id="t13"></a>
### 13. Conteneurs

- **Qui / durée** : 🤖 · ~5 à 10 min
- **Objectif** : démarrer toute la pile : sites, tunnels Cloudflare, dashboard, Netdata, Dozzle, Uptime Kuma, GameVault, Homewatch.
- **Commandes exécutées** (étape `7/7`) :
  ```bash
  cd ~/docker
  docker compose up -d
  docker compose ps
  ```
  Le premier lancement télécharge les images et **construit** l'image de Homewatch (installation des dépendances Python sur le Pi : le plus long).
- **Résultat attendu** : une liste de conteneurs `Up`. **Homewatch redémarre en boucle** tant que la tâche 15 n'est pas faite : c'est normal et sans danger, il n'expose rien.
- **Si ça coince** : un conteneur `cloudflared-<service>` en erreur → `Provided Tunnel token is not valid` = `.env` mal formé (relire la sortie de la tâche 9) ; `docker compose logs <service>` pour le détail.

<a id="t14"></a>
### 14. Redémarrage

- **Qui / durée** : 🤖 · ~2 min
- **Objectif** : activer le ventilateur Argon ; les conteneurs repartent seuls (`restart: unless-stopped`).
- **Action** : le script annonce un redémarrage dans 10 secondes puis exécute `sudo reboot`. Attendre environ 2 minutes, puis :
  ```bash
  ping -c 3 maxime.local
  ```
- **Résultat attendu** : le Pi répond de nouveau. La connexion SSH du script est fermée : c'est normal.

---

## Phase 3 : après le redémarrage

<a id="t15"></a>
### 15. Homewatch : première connexion

- **Qui / durée** : 🧑 · ~3 min
- **Objectif** : ouvrir une session auprès du service des caméras. Le jeton de session **n'est pas sauvegardé** (c'est un accès au compte) et ni l'e-mail ni le mot de passe ne sont jamais écrits sur le disque : seuls des jetons le sont, et ils se renouvellent seuls ensuite.
- **Commandes** (sur le Pi, `ssh maxime@maxime.local`) :
  ```bash
  cd ~/docker
  docker compose run --rm homewatch
  ```
  Saisir l'adresse e-mail du compte, son mot de passe, puis le **code de vérification** reçu. Quand la liste des caméras s'affiche (« Connecté. N caméra(s) trouvée(s) »), **Ctrl-C**, puis :
  ```bash
  docker compose up -d homewatch
  docker compose logs --tail 10 homewatch
  ```
- **Résultat attendu** : les logs montrent la liste des caméras sans aucune question ; `homewatch.<domaine>` (derrière Cloudflare Access) affiche les flux.
- **Si ça coince** : erreur `429` ou « trop de tentatives » → attendre un moment, **ne pas enchaîner les essais** ; code refusé → en redemander un ; deux conteneurs actifs en même temps → l'un invalide le jeton de l'autre (n'en garder qu'un).

<a id="t16"></a>
### 16. Réappliquer le durcissement SSH

- **Qui / durée** : 🧑 · ~5 min
- **Objectif** : la carte neuve accepte de nouveau les mots de passe. Revenir à « clé SSH uniquement » (mots de passe et `root` désactivés). Détails et raisons : [`ajouter-un-site.md`, « Durcissement SSH »](ajouter-un-site.md).
- **Commandes** (clé déjà présente sur le Mac, avec son bloc `Host maxime.local` dans `~/.ssh/config`) :
  1. Installer la clé (dernier mot de passe saisi) :
     ```bash
     ssh-copy-id -i ~/.ssh/id_ed25519_homelab.pub maxime@maxime.local
     ```
  2. **Avant** de couper les mots de passe, vérifier que la clé seule suffit :
     ```bash
     ssh -o PreferredAuthentications=publickey -o PasswordAuthentication=no maxime@maxime.local 'echo clé OK'
     ```
  3. Ouvrir une session sur le Pi et **la laisser ouverte** (porte de secours), puis :
     ```bash
     sudo tee /etc/ssh/sshd_config.d/00-hardening.conf > /dev/null <<'EOF'
     PasswordAuthentication no
     KbdInteractiveAuthentication no
     PermitRootLogin no
     PubkeyAuthentication yes
     AuthenticationMethods publickey
     MaxAuthTries 3
     LoginGraceTime 30
     EOF
     sudo sshd -t
     sudo sshd -T | grep -iE '^(passwordauthentication|permitrootlogin|pubkeyauthentication|authenticationmethods)'
     sudo systemctl reload ssh
     ```
  4. Dans un **nouveau** terminal : la connexion par clé réussit, et ceci doit répondre `Permission denied (publickey)` :
     ```bash
     ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no maxime@maxime.local
     ```
- **Résultat attendu** : `clé OK`, `passwordauthentication no`, et le refus par mot de passe.
- **Si ça coince** : annuler depuis la session restée ouverte : `sudo rm /etc/ssh/sshd_config.d/00-hardening.conf && sudo systemctl reload ssh`. Le préfixe `00-` est voulu : le premier réglage rencontré l'emporte.

<a id="t17"></a>
### 17. Vérifier les services

- **Qui / durée** : 🧑 · ~5 min
- **Objectif** : confirmer que tout est reparti, y compris les données restaurées.
- **Commandes et contrôles** :
  ```bash
  ssh maxime@maxime.local
  docker compose -f ~/docker/docker-compose.yml ps        # tous les conteneurs Up
  vcgencmd get_throttled                                   # throttled=0x0 : alimentation et température correctes
  bash ~/docker/pi/verifier-acces.sh                       # chaque sous-domaine : conforme (Access / public)
  ```
  Dans le navigateur :
  - `www.<domaine>` (public) et `config.<domaine>` (e-mail + code + MFA)
  - `gamevault.<domaine>` (derrière Access) : le catalogue de jeux est là, avec la même base qu'avant
  - `uptime.<domaine>` : compte, sondes et notification ntfy déjà présents, aucune reconfiguration
- **Résultat attendu** : tout `Up` ; `verifier-acces.sh` affiche « Tout est conforme » ; données retrouvées.
- **Si ça coince** : tableau de dépannage dans [`restauration-carte-sd.md`](restauration-carte-sd.md) (« Si ça coince »), notamment Cloudflare `1033` (conteneur du tunnel arrêté) et `403` nginx (dossier appartenant à `root` : `sudo chown -R maxime:maxime ~/docker/<service>`).

<a id="t18"></a>
### 18. Retrouver le partage Samba

- **Qui / durée** : 🧑 · ~1 min
- **Objectif** : remonter `~/docker` du Pi sur le Mac.
- **Action** : Finder → `Cmd+K` → `smb://maxime.local/docker`, avec l'utilisateur `maxime` et le mot de passe choisi à la tâche 11.
- **Résultat attendu** : le volume apparaît (`/Volumes/docker`).
- **Si ça coince** : Finder refuse la connexion → le mot de passe a changé : supprimer l'entrée `maxime.local` dans Trousseau d'accès, puis refaire `Cmd+K`.

<a id="t19"></a>
### 19. Contrôler la sauvegarde quotidienne

- **Qui / durée** : 🧑 · ~1 min
- **Objectif** : s'assurer que la nouvelle carte sauvegarde bien, avec les mêmes clés.
- **Commandes** (sur le Pi) :
  ```bash
  systemctl list-timers homelab-backup          # prochaine exécution (~03h30)
  sudo systemctl start homelab-backup           # facultatif : forcer une sauvegarde maintenant
  journalctl -u homelab-backup -n 30 --no-pager
  ```
- **Résultat attendu** : `Terminé : homelab-AAAA-MM-JJ.tar.gz.age (...), N archive(s) sur GitHub` ; l'archive du jour apparaît sur la page GitHub du dépôt. Si le moniteur Push d'Uptime Kuma est configuré (son URL est dans l'archive), il passe au vert.
- **Si ça coince** : `Permission denied (publickey)` à l'envoi → la clé d'écriture n'est plus enregistrée dans les Deploy keys du dépôt `maximelabatut-backups` (avec « Allow write access ») ; échec avant l'envoi → rien n'est remplacé sur GitHub, lire le message dans le journal.

---

## Et ensuite

- Une sauvegarde jamais restaurée n'est pas une garantie : **répéter cette procédure sur une carte de rechange**, sans toucher à la carte en service, puis mettre à jour les durées de ce document avec les valeurs mesurées.
- Supprimer les anciennes copies en clair du dossier `~/Backups/raspberrypi` du Mac, devenues inutiles (cf. [« Migration depuis l'ancienne sauvegarde »](ajouter-un-site.md)).
