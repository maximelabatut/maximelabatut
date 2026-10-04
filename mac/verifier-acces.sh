#!/bin/bash
# Vérifie, depuis l'extérieur et sans être connecté, que chaque sous-domaine est protégé par Cloudflare Access
# (ou public) comme prévu. Un sous-domaine censé être protégé qui ne l'est pas est une EXPOSITION : le script
# le signale et sort en erreur.
#   verifier-acces.sh            tableau complet
#   verifier-acces.sh --quiet    n'affiche que les anomalies (utilisé par la sauvegarde nocturne)
#
# Codes de sortie : 0 = conforme, 1 = anomalie d'exposition, 2 = réseau indisponible (rien n'a pu être vérifié).
#
# Principe : une application derrière Access répond toujours par un 302 vers *.cloudflareaccess.com, même si son
# conteneur est arrêté. Une réponse différente (200, 5xx, redirection ailleurs) veut dire qu'Access ne l'intercepte pas.
#
# RÈGLE : toute nouvelle application ajoutée au docker-compose.yml doit être ajoutée ci-dessous.
set -uo pipefail

DOMAIN="${DOMAIN:-maximelabatut.com}"
PUBLIC_HOSTS="${PUBLIC_HOSTS:-www web2}"
PROTECTED_HOSTS="${PROTECTED_HOSTS:-config netdata logs uptime gamevault homewatch}"
QUIET=0; [ "${1:-}" = "--quiet" ] && QUIET=1

anomalies=0; injoignables=0; total=0

check() {  # $1 = sous-domaine, $2 = attendu (access|public)
  local host="$1.$DOMAIN" expected="$2" out code red state ok
  out="$(curl -s -o /dev/null -m 15 -w '%{http_code}|%{redirect_url}' "https://$host/" 2>/dev/null || true)"
  code="${out%%|*}"; red="${out#*|}"
  total=$((total + 1))
  if [ "$code" = "000" ] || [ -z "$code" ]; then
    injoignables=$((injoignables + 1)); [ "$QUIET" = 1 ] || printf "  %-30s %s\n" "$host" "non vérifié (réseau)"; return
  fi
  case "$red" in
    *cloudflareaccess.com*) state="access" ;;
    "") state="public:$code" ;;
    *) state="autre:${red#https://}" ;;
  esac
  ok=0
  if [ "$expected" = "access" ] && [ "$state" = "access" ]; then ok=1; fi
  if [ "$expected" = "public" ] && [ "$state" = "public:200" ]; then ok=1; fi
  if [ "$ok" = 1 ]; then
    [ "$QUIET" = 1 ] || printf "  %-30s %s\n" "$host" "conforme ($expected)"
  else
    anomalies=$((anomalies + 1))
    case "$expected" in
      access) printf "  %-30s ANOMALIE : devrait être protégé par Access, répond %s\n" "$host" "$state" ;;
      public) printf "  %-30s ANOMALIE : devrait être public (HTTP 200), répond %s\n" "$host" "$state" ;;
    esac
  fi
}

[ "$QUIET" = 1 ] || echo "Contrôle d'accès de *.$DOMAIN (sans être connecté) :"
for h in $PROTECTED_HOSTS; do check "$h" access; done
for h in $PUBLIC_HOSTS; do check "$h" public; done

if [ "$injoignables" -eq "$total" ]; then
  [ "$QUIET" = 1 ] || echo "Réseau indisponible : aucun contrôle possible."; exit 2
fi
if [ "$anomalies" -gt 0 ]; then
  echo "$anomalies anomalie(s) d'exposition : corriger les destinations de l'application Cloudflare Access."; exit 1
fi
[ "$QUIET" = 1 ] || echo "Tout est conforme."
exit 0
