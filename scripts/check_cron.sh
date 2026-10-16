#!/bin/bash
set -euo pipefail

##### INSTRUCTION
#
# Verifie que les taches planifiees de Dolibarr tournent. Lance par :  make cron
#
#   1. Le conteneur dolibarr-cron tourne-t-il, avec une cle ET un utilisateur ?
#   2. Le module « Travaux planifies » est-il actif ?
#   3. La cle en base (CRON_KEY) est-elle celle du .env (DOLI_CRON_KEY) ?
#   4. Quand une tache a-t-elle tourne pour la derniere fois ?
#
# Le point 3 est le piege : le module Travaux planifies cree CRON_KEY VIDE a son
# activation, apres l'installation. L'image ne peut donc pas la poser. Tant
# qu'elle differe, chaque passage repond « securitykey ... does not match » et
# aucune tache ne tourne. Si elle est vide, ce script la remplit avec
# DOLI_CRON_KEY. Si elle est remplie mais differente, il n'ecrase rien.
#
# Sort en code non nul si quoi que ce soit cloche : utilisable en monitoring.
#####

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
STACK_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$STACK_DIR/.env"

ok()      { echo "  [ok]   $*"; }
ko()      { echo "  [KO]   $*" >&2; ERREURS=$((ERREURS + 1)); }
info()    { echo "  [..]   $*"; }
erreur()  { echo "[cron] ERREUR : $*" >&2; exit 2; }
compose() { docker compose -f "$STACK_DIR/docker-compose.yml" "$@"; }
sql()     { printf '%s\n' "$1" | compose exec -T dolibarr-mariadb sh -c 'exec mariadb -u root -p"$MARIADB_ROOT_PASSWORD" -N dolibarr'; }
ERREURS=0

[ -f "$ENV_FILE" ] || erreur ".env introuvable : $ENV_FILE"
set -a
# shellcheck disable=SC1090
. "$ENV_FILE"
set +a

: "${DOLI_CRON_KEY:?DOLI_CRON_KEY absent du .env}"
[ -n "$(compose ps --status running -q dolibarr-mariadb)" ] || erreur "la base ne tourne pas : make up."


#### 1. CONTENEUR ####
echo "1. Conteneur dolibarr-cron"

if [ -z "$(compose ps --status running -q dolibarr-cron)" ]; then
  ko "dolibarr-cron ne tourne pas. Il attend que dolibarr soit healthy : make ps, puis make up."
else
  # La ligne que l'image a ecrite au demarrage : c'est elle qui tourne vraiment.
  LIGNE="$(compose exec -T dolibarr-cron cat /etc/cron.d/dolibarr 2>/dev/null | grep cron_run_jobs.php || true)"
  CLE_CONTENEUR="$(printf '%s' "$LIGNE" | sed -n "s/.*cron_run_jobs.php \([^ ]*\) \([^ ']*\)'.*/\1/p")"
  USER_CONTENEUR="$(printf '%s' "$LIGNE" | sed -n "s/.*cron_run_jobs.php \([^ ]*\) \([^ ']*\)'.*/\2/p")"

  if [ -z "$LIGNE" ]; then
    ko "aucune ligne cron dans le conteneur (/etc/cron.d/dolibarr)."
  elif [ "$CLE_CONTENEUR" != "$DOLI_CRON_KEY" ]; then
    ko "le conteneur tourne avec une autre cle que le .env : make up pour le recreer."
  elif [ -z "$USER_CONTENEUR" ]; then
    ko "aucun utilisateur (DOLI_CRON_USER) : chaque passage s'arrete sur « Usage: ... »."
  else
    ok "passage toutes les 5 minutes, utilisateur '$USER_CONTENEUR'"
  fi
fi


#### 2. MODULE ####
echo "2. Module Travaux planifies"

if [ "$(sql "SELECT value FROM llx_const WHERE name = 'MAIN_MODULE_CRON' AND entity = 1")" = 1 ]; then
  ok "actif"
else
  ko "inactif. Configuration -> Modules/Applications -> Travaux planifies (un module qui a des taches, comme TiBillet, l'active seul)."
fi


#### 3. CLE ####
echo "3. Cle des taches planifiees"

# Pas de ligne = module jamais active (deja signale au point 2).
NB_CLES="$(sql "SELECT COUNT(*) FROM llx_const WHERE name = 'CRON_KEY' AND entity = 0")"
# Saisie dans l'interface, la cle est stockee CHIFFREE (« dolcrypt:... », avec
# DOLI_INSTANCE_UNIQUE_ID) : on la lit par Dolibarr lui-meme, qui la dechiffre.
CLE_BASE="$(compose exec -T dolibarr php -r '
  foreach (array("NOLOGIN", "NOSESSION", "NOREQUIREMENU", "NOREQUIREHTML", "NOREQUIREAJAX") as $c) define($c, 1);
  $_SERVER["PHP_SELF"] = "check_cron";
  require "/var/www/html/master.inc.php";
  echo getDolGlobalString("CRON_KEY");')" || erreur "lecture de la cle impossible : dolibarr tourne-t-il ? (make ps)"

if [ "$NB_CLES" = 0 ]; then
  ko "pas encore de cle en base : activer d'abord le module (point 2), puis relancer make cron."
elif [ -z "$CLE_BASE" ]; then
  # DOLI_CRON_KEY sort de openssl rand -hex : rien a echapper dans le SQL.
  # Ecrite en clair, comme le fait l'image : Dolibarr lit tel quel ce qui
  # ne commence pas par « dolcrypt: ».
  sql "UPDATE llx_const SET value = '$DOLI_CRON_KEY' WHERE name = 'CRON_KEY' AND entity = 0"
  ok "cle vide en base : remplie avec DOLI_CRON_KEY du .env"
elif [ "$CLE_BASE" = "$DOLI_CRON_KEY" ]; then
  ok "identique au .env"
else
  ko "la cle en base differe du .env. Coller DOLI_CRON_KEY du .env dans
         Configuration -> Modules/Applications -> Travaux planifies -> roue dentee,
         « Cle de securite pour l'URL de lancement des travaux programmes »."
fi


#### 4. DERNIERE EXECUTION ####
echo "4. Derniere execution"

DERNIERE="$(sql "SELECT IFNULL(MAX(datelastrun), '') FROM llx_cronjob WHERE status = 1")"
if [ -n "$DERNIERE" ]; then
  info "derniere tache lancee : $DERNIERE"
else
  info "aucune tache n'a encore tourne (le premier passage arrive dans les 5 minutes)."
fi
info "logs du conteneur :  docker compose logs --tail 20 dolibarr-cron"


#### VERDICT ####
echo
if [ "$ERREURS" -eq 0 ]; then
  echo "[cron] Les taches planifiees sont pretes."
  exit 0
fi
echo "[cron] $ERREURS probleme(s). Aucune tache planifiee ne tourne tant que ce n'est pas regle." >&2
exit 1
