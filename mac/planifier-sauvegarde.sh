#!/bin/bash
# Planifie la sauvegarde du Pi chaque nuit avec launchd (agent utilisateur, actif quand la session est ouverte).
#   planifier-sauvegarde.sh install     installe et active la tâche (tous les jours à 03h30 ; si le Mac dort, elle part au réveil)
#   planifier-sauvegarde.sh run         la lance tout de suite (même mode que la nuit : sans terminal)
#   planifier-sauvegarde.sh status      état de la tâche + fin du journal
#   planifier-sauvegarde.sh uninstall   la supprime
# Le script planifié et ses données doivent être hors du Bureau/Documents : macOS interdit à une tâche
# launchd de lire ces dossiers (protection de la vie privée). Valeur par défaut : ~/Backups/raspberrypi.
set -euo pipefail

LABEL="fr.maximelabatut.homelab-backup"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
SCRIPT="${SCRIPT:-$HOME/Backups/raspberrypi/sauvegarder-pi.sh}"
LOG="$HOME/Library/Logs/homelab-backup.log"
HOUR="${HOUR:-3}"
MINUTE="${MINUTE:-30}"
DOMAIN="gui/$(id -u)"

case "${1:-status}" in
  install)
    [ -x "$SCRIPT" ] || { echo "Script introuvable ou non exécutable : $SCRIPT"; exit 1; }
    case "$SCRIPT" in
      "$HOME/Desktop/"*|"$HOME/Documents/"*|"$HOME/Downloads/"*)
        echo "Refusé : $SCRIPT est dans un dossier protégé par macOS, la tâche planifiée ne pourrait pas le lire."; exit 1;;
    esac
    mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
    cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array><string>/bin/bash</string><string>$SCRIPT</string><string>--auto</string></array>
  <key>StartCalendarInterval</key>
  <dict><key>Hour</key><integer>$HOUR</integer><key>Minute</key><integer>$MINUTE</integer></dict>
  <key>StandardErrorPath</key><string>$LOG</string>
  <key>ProcessType</key><string>Background</string>
</dict>
</plist>
EOF
    plutil -lint "$PLIST" >/dev/null
    launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
    launchctl bootstrap "$DOMAIN" "$PLIST"
    printf "Tâche installée : tous les jours à %02d:%02d (%s)\n" "$HOUR" "$MINUTE" "$SCRIPT"
    echo "Journal : $LOG"
    ;;
  run)
    launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1 || { echo "Tâche non installée : planifier-sauvegarde.sh install"; exit 1; }
    launchctl kickstart -k "$DOMAIN/$LABEL"
    echo "Lancée. Suivre : tail -f $LOG"
    ;;
  status)
    if launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
      echo "Tâche installée ($LABEL)."
      launchctl print "$DOMAIN/$LABEL" | grep -E "^\s*(state|runs|last exit code|program) " | sed 's/^/  /' || true
    else
      echo "Tâche non installée."
    fi
    [ -f "$LOG" ] && { echo "--- fin du journal ---"; tail -12 "$LOG"; } || echo "(pas encore de journal)"
    ;;
  uninstall)
    launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
    rm -f "$PLIST"
    echo "Tâche supprimée."
    ;;
  *)
    echo "Usage : $0 install | run | status | uninstall"; exit 1;;
esac
