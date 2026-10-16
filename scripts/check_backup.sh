#!/bin/bash
set -euo pipefail

##### INSTRUCTION
#
# Verifie que la derniere sauvegarde est REELLEMENT restaurable, sans rien
# restaurer. Lance par :  make check
#
#   1. Une archive recente existe-t-elle ? (sinon : le cron est mort)
#   2. Contient-elle le dump, documents/ et le .env ?
#   3. Le dump est-il exploitable — et COMPLET ?
#
# Le point 3 est celui qui compte : un dump tronque (disque plein, conteneur tue)
# a la bonne taille, est bien dans l'archive, et ne se restaure pas.
# mariadb-dump termine par "-- Dump completed" : c'est la preuve de non-troncature.
#
# Sort en code non nul si quoi que ce soit cloche : utilisable en monitoring.
#####

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
STACK_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$STACK_DIR/.env"

AGE_MAX_HEURES="${AGE_MAX_HEURES:-25}"

ok()      { echo "  [ok]   $*"; }
ko()      { echo "  [KO]   $*" >&2; ERREURS=$((ERREURS + 1)); }
erreur()  { echo "[check] ERREUR : $*" >&2; exit 2; }
ERREURS=0

[ -f "$ENV_FILE" ] || erreur ".env introuvable : $ENV_FILE"
set -a
# shellcheck disable=SC1090
. "$ENV_FILE"
set +a

: "${BORG_PREFIX:?BORG_PREFIX absent du .env — sauvegarde non configuree, lancer make init}"
: "${BORG_REPO:?BORG_REPO absent du .env — sauvegarde non configuree, lancer make init}"
: "${BORG_PASSPHRASE:?BORG_PASSPHRASE absent du .env}"
command -v borg >/dev/null || erreur "borg introuvable dans le PATH."

SSH_KEY="$SCRIPT_DIR/.ssh/${BORG_PREFIX}_ed25519"
[ -f "$SSH_KEY" ] && export BORG_RSH="/usr/bin/ssh -oStrictHostKeyChecking=accept-new -oIdentitiesOnly=yes -i $SSH_KEY"

echo "[check] depot : $BORG_REPO"
echo


#### 1. FRAICHEUR ####
echo "1. Fraicheur"

DERNIERE="$(borg list --glob-archives "$BORG_PREFIX-*" --last 1 \
  --format '{archive}{TAB}{time:%Y-%m-%d %H:%M:%S}{NL}' "$BORG_REPO")"
[ -n "$DERNIERE" ] || erreur "aucune archive '$BORG_PREFIX-*' dans le depot. La sauvegarde n'a jamais tourne."

ARCHIVE="${DERNIERE%%	*}"
DATE_ARCHIVE="${DERNIERE#*	}"
AGE_HEURES=$(( ( $(date +%s) - $(date -d "$DATE_ARCHIVE" +%s) ) / 3600 ))

if [ "$AGE_HEURES" -le "$AGE_MAX_HEURES" ]; then
  ok "derniere archive : $ARCHIVE (il y a ${AGE_HEURES} h)"
else
  ko "derniere archive : $ARCHIVE — ${AGE_HEURES} h, soit plus de ${AGE_MAX_HEURES} h."
  ko "le cron ne tourne plus. Verifie : crontab -l"
fi


#### 2. CONTENU ####
echo
echo "2. Contenu de l'archive"

CONTENU="$(borg list --format '{path}{NL}' "$BORG_REPO::$ARCHIVE")"

CHEMIN_DUMP="$(printf '%s\n' "$CONTENU" | grep -E '/scripts/dump-[^/]+/dolibarr\.sql$' | head -n1 || true)"
if [ -n "$CHEMIN_DUMP" ]; then
  ok "dump SQL present : ${CHEMIN_DUMP##*/}"
else
  ko "aucun dump SQL dans l'archive."
fi

# install.lock est toujours dans documents/ une fois Dolibarr installe.
if printf '%s\n' "$CONTENU" | grep -qE '/documents/install\.lock$'; then
  ok "documents/ present"
else
  ko "documents/ absent de l'archive (fichiers joints, PDF)."
fi

if printf '%s\n' "$CONTENU" | grep -qE '/\.env$'; then
  ok ".env present (la stack est remontable telle quelle)"
else
  ko ".env absent : une restauration demanderait de resaisir les secrets."
fi


#### 3. LE DUMP ####
echo
echo "3. Le dump est-il restaurable ?"

if [ -z "$CHEMIN_DUMP" ]; then
  ko "pas de dump a verifier."
else
  # On lit tout le flux (pas de grep -q qui fermerait le tuyau : SIGPIPE + pipefail).
  VERDICT="$(borg extract --stdout "$BORG_REPO::$ARCHIVE" "$CHEMIN_DUMP" | awk '
    /CREATE TABLE `llx_societe`/ { societe = 1 }
    /CREATE TABLE `llx_user`/    { users = 1 }
    /^-- Dump completed/         { complet = 1 }
    END { printf "%d %d %d", societe + 0, users + 0, complet + 0 }
  ')"
  read -r A_SOCIETE A_USERS COMPLET <<< "$VERDICT"

  if [ "$A_SOCIETE" = 1 ] && [ "$A_USERS" = 1 ]; then
    ok "schema Dolibarr retrouve (tables llx_societe et llx_user)"
  else
    ko "le dump ne contient pas le schema Dolibarr attendu."
  fi

  if [ "$COMPLET" = 1 ]; then
    ok "dump complet (mariadb-dump est alle au bout)"
  else
    ko "dump TRONQUE : pas de '-- Dump completed' en fin de fichier."
  fi
fi


#### VERDICT ####
echo
if [ "$ERREURS" -eq 0 ]; then
  echo "[check] La derniere sauvegarde est restaurable."
  exit 0
fi
echo "[check] $ERREURS probleme(s). Cette sauvegarde n'est pas fiable." >&2
exit 1
