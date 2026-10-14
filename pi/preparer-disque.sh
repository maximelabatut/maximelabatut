#!/bin/bash
# Disque de stockage USB du Pi, partagé en SMB sur le réseau local.
#
#   sudo bash ~/docker/pi/preparer-disque.sh             REMONTER un disque déjà préparé (carte SD neuve, disque intact) : ne formate JAMAIS
#   sudo bash ~/docker/pi/preparer-disque.sh /dev/sdX    PRÉPARER un disque NEUF : efface, formate, monte, partage
#
# Remontage : retrouve la partition ext4 d'étiquette « stockage », la monte dans /srv/stockage (fstab, nofail), réécrit le partage Samba
# « Stockage » et crée l'utilisateur Samba si besoin. Les fichiers du disque ne sont pas touchés.
# Disque neuf : refuse tout disque qui n'est pas USB, qui est celui du système, qui est monté, qui contient des partitions ou des
# signatures ; contrôle SMART ; demande de retaper le chemin du disque avant d'effacer.
# Relançable sans risque. À lancer avec sudo, depuis le Pi.
set -euo pipefail

LABEL=stockage
MNT=/srv/stockage
SHARE=Stockage
SMB_USER=maxime
CONF=/etc/samba/smb.conf
ARG_DEV="${1:-}"

say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
die() { printf '\n\033[31mARRÊT : %s\033[0m\n' "$*" >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || die "à lancer avec sudo :  sudo bash $0 [/dev/sdX]"
id "$SMB_USER" >/dev/null 2>&1 || die "l'utilisateur « $SMB_USER » n'existe pas sur ce Pi"

# Réseau autorisé à joindre le partage : celui de l'interface par défaut (ex. 192.168.1.0/24), sinon valeur de repli.
LAN="${LAN:-$(dev=$(ip -4 route show default | awk '{print $5; exit}'); ip -4 route show dev "$dev" proto kernel scope link 2>/dev/null | awk '{print $1; exit}')}"
LAN="${LAN:-192.168.1.0/24}"

# ---------------------------------------------------------------------------------------------------------------------
say "Paquets"
need=""
command -v smbd >/dev/null || need="samba samba-common-bin"
command -v smartctl >/dev/null || need="$need smartmontools"
[ -z "$need" ] || { apt-get update -y >/dev/null; apt-get install -y $need >/dev/null; }
echo "  samba et smartmontools présents"

# ---------------------------------------------------------------------------------------------------------------------
say "Disque"
PART=$(blkid -L "$LABEL" 2>/dev/null || true)
if [ -n "$PART" ]; then
  [ -z "$ARG_DEV" ] || die "une partition « $LABEL » existe déjà ($PART) : je ne formate pas. Pour la remonter, relance sans argument."
  MODE=remontage
  echo "  partition « $LABEL » retrouvée : $PART (mode REMONTAGE : aucune donnée n'est touchée)"
else
  MODE=neuf
  if [ -z "$ARG_DEV" ]; then
    echo "  aucune partition d'étiquette « $LABEL » : disque neuf, ou débranché ? Disques USB vus :"
    lsblk -d -o NAME,SIZE,MODEL,SERIAL,TRAN | awk 'NR==1 || $NF=="usb"'
    die "pour préparer un disque NEUF : sudo bash $0 /dev/sdX   (le disque sera effacé)"
  fi
  DEV="$ARG_DEV"
  [ -b "$DEV" ] || die "$DEV n'existe pas"
  [ "$(lsblk -dn -o TYPE "$DEV")" = "disk" ] || die "$DEV n'est pas un disque entier (donne /dev/sda, pas /dev/sda1)"
  [ "$(lsblk -dn -o TRAN "$DEV")" = "usb" ] || die "$DEV n'est pas un disque USB : refus par sécurité"
  root_src=$(findmnt -n -o SOURCE /)
  case "$root_src" in "$DEV"*) die "$DEV porte le système" ;; esac
  lsblk -nr -o MOUNTPOINT "$DEV" | grep -q . && die "$DEV (ou une de ses partitions) est monté : démonte-le d'abord"
  [ "$(lsblk -n -o NAME "$DEV" | wc -l)" -eq 1 ] || { lsblk "$DEV"; die "$DEV contient déjà des partitions : je n'efface rien"; }
  [ -z "$(wipefs -n "$DEV" 2>/dev/null)" ] || { wipefs -n "$DEV"; die "des signatures de système de fichiers existent sur $DEV : je n'efface rien"; }
  model=$(lsblk -dn -o MODEL "$DEV" | xargs); serial=$(lsblk -dn -o SERIAL "$DEV" | xargs); size=$(lsblk -dn -o SIZE "$DEV" | xargs)
  echo "  $DEV : $model, série $serial, $size : vide (aucune partition, aucune signature)"

  say "État du disque (SMART)"
  SMART=$(smartctl -d sat -H -A -i "$DEV" 2>&1) || true
  printf '%s\n' "$SMART" | grep -E "Device Model|Serial Number|User Capacity|SMART overall|Power_On_Hours|Reallocated_Sector_Ct|Current_Pending_Sector|Offline_Uncorrectable|UDMA_CRC_Error|Temperature_Celsius" || true
  if printf '%s\n' "$SMART" | grep -qE "SMART overall-health self-assessment test result: PASSED"; then
    echo "  SMART : PASSED"
  elif printf '%s\n' "$SMART" | grep -qiE "FAILED|failing now"; then
    die "SMART signale une défaillance : ne confie pas de données à ce disque"
  else
    echo "  AVERTISSEMENT : SMART illisible à travers ce boîtier USB (fréquent) : état non vérifié."
  fi
  bad=$(printf '%s\n' "$SMART" | awk '/Reallocated_Sector_Ct|Current_Pending_Sector|Offline_Uncorrectable/ {s+=$NF} END {print s+0}')
  [ "$bad" -eq 0 ] || echo "  ATTENTION : $bad secteur(s) défectueux ou en attente : disque peu fiable."

  say "Confirmation"
  echo "  Ce disque va être EFFACÉ : $DEV ($model, série $serial, $size), puis partitionné (GPT), formaté en ext4 « $LABEL »,"
  echo "  monté dans $MNT et partagé en SMB (« $SHARE », utilisateur $SMB_USER, réseau $LAN)."
  read -r -p "  Retape le chemin du disque ($DEV) pour confirmer : " answer
  [ "$answer" = "$DEV" ] || die "annulé, rien n'a été modifié"

  say "Partition et système de fichiers"
  parted -s "$DEV" mklabel gpt mkpart "$LABEL" ext4 1MiB 100%
  partprobe "$DEV"; udevadm settle; sleep 2
  PART=$(lsblk -nrp -o NAME "$DEV" | sed -n 2p)
  [ -b "$PART" ] || die "la partition n'est pas apparue sur $DEV"
  mkfs.ext4 -F -L "$LABEL" -m 0 "$PART"      # -m 0 : aucune réserve root (disque de données)
fi
UUID=$(blkid -s UUID -o value "$PART")
echo "  $PART  UUID=$UUID"

# ---------------------------------------------------------------------------------------------------------------------
say "Montage automatique ($MNT)"
mkdir -p "$MNT"
# Une seule ligne fstab pour ce point de montage (la nôtre, à jour) : nofail + attente de 30 s du disque (un 3,5" met quelques
# secondes à tourner) ; un disque absent ou en panne ne bloque JAMAIS le démarrage du Pi.
LINE="UUID=$UUID  $MNT  ext4  defaults,noatime,nofail,x-systemd.device-timeout=30  0  2"
if ! grep -qxF "$LINE" /etc/fstab; then
  cp /etc/fstab "/etc/fstab.bak-$(date +%Y%m%d-%H%M%S)"
  sed -i "\|[[:space:]]$MNT[[:space:]]|d" /etc/fstab
  echo "$LINE" >> /etc/fstab
fi
systemctl daemon-reload
mountpoint -q "$MNT" || mount "$MNT"
mountpoint -q "$MNT" || die "le montage de $MNT a échoué"
chown "$SMB_USER":users "$MNT"
chmod 2775 "$MNT"
df -h "$MNT" | tail -1

# ---------------------------------------------------------------------------------------------------------------------
say "Partage Samba « $SHARE »"
cp "$CONF" "$CONF.bak-$(date +%Y%m%d-%H%M%S)"
sed -i '/^# >>> HOMELAB-STOCKAGE/,/^# <<< HOMELAB-STOCKAGE/d;/^# >>> GAMEVAULT-STOCKAGE/,/^# <<< GAMEVAULT-STOCKAGE/d' "$CONF"
FRUIT=""
if ls /usr/lib/*/samba/vfs/fruit.so >/dev/null 2>&1; then
  FRUIT=$'   vfs objects = fruit streams_xattr\n   fruit:metadata = stream\n   fruit:model = MacSamba\n   fruit:posix_rename = yes\n   fruit:veto_appledouble = no\n   fruit:nfs_aces = no\n   fruit:wipe_intentionally_left_blank_rfork = yes\n   fruit:delete_empty_adfiles = yes'
fi
cat >> "$CONF" <<EOF
# >>> HOMELAB-STOCKAGE (bloc géré par preparer-disque.sh : le modifier ici ou relancer le script)
[$SHARE]
   comment = Disque de stockage du Pi
   path = $MNT
   browseable = yes
   read only = no
   guest ok = no
   valid users = $SMB_USER
   hosts allow = $LAN 127.0.0.1 fe80::/10 ::1
   force group = users
   create mask = 0664
   directory mask = 2775
   veto files = /lost+found/
$FRUIT
# <<< HOMELAB-STOCKAGE
EOF
testparm -s >/dev/null 2>&1 || { testparm -s 2>&1 | tail -20; die "configuration Samba invalide (ancienne version : $CONF.bak-*)"; }
if ! pdbedit -L 2>/dev/null | grep -q "^$SMB_USER:"; then
  echo "  Choisis le mot de passe SMB de « $SMB_USER » (propre au partage, distinct du mot de passe de connexion du Pi) :"
  smbpasswd -a "$SMB_USER"
fi
systemctl enable smbd >/dev/null 2>&1 || true
systemctl restart smbd
sleep 1
systemctl is-active smbd >/dev/null || die "smbd ne démarre pas (journalctl -u smbd)"

say "Terminé ($MODE)"
IP=$(hostname -I | awk '{print $1}')
cat <<EOF
  Disque : $MNT  ($(df -h --output=size,avail "$MNT" | tail -1 | awk '{print $1" au total, "$2" libres"}'))
  Mac     : Finder > Aller > Se connecter au serveur :  smb://$(hostname).local/$SHARE   (ou smb://$IP/$SHARE)
  Windows : \\\\$IP\\$SHARE
  Utilisateur : $SMB_USER (mot de passe SMB). Si le Mac refuse après une réinstallation : supprimer l'entrée du Pi dans Trousseau d'accès.
  Fichiers modifiés (sauvegardes datées) : /etc/fstab.bak-*  et  $CONF.bak-*
EOF
