#!/bin/bash
set -euo pipefail

##### INSTRUCTION
#
# Restaure une archive borg dans cette stack. Lance par :  make restore
#
# ECRASE : la base 'dolibarr', documents/ et custom/. Le .env est remplace par
# celui de l'archive s'il differe (l'actuel est garde en .env.avant-restauration).
#
#   choix de l'archive -> confirmation tapee -> extraction dans restauration-tmp/
#   -> arret de Dolibarr -> .env -> base recreee et dump injecte
#   -> documents/ et custom/ remplaces -> redemarrage
#
# Sert aussi apres la perte du serveur : voir la section Restauration du README.
#
# Pourquoi restaurer le .env de l'archive : il porte le sel de chiffrement et la
# majeure de Dolibarr (DOLIBARR_VERSION) de la sauvegarde. Une base restauree
# sous une autre majeure, ou avec un autre sel, ne fonctionne pas.
#####

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
STACK_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$STACK_DIR/.env"
TMP_DIR="$STACK_DIR/restauration-tmp"

dire()   { echo "[restore] $*"; }
erreur() { echo "[restore] ERREUR : $*" >&2; exit 1; }
compose() { docker compose -f "$STACK_DIR/docker-compose.yml" "$@"; }

[ -t 0 ] || erreur "make restore est interactif : lance-le depuis un terminal."
[ -f "$ENV_FILE" ] || erreur ".env introuvable : $ENV_FILE"
for outil in borg docker rsync; do
  command -v "$outil" >/dev/null || erreur "$outil introuvable dans le PATH."
done

set -a
# shellcheck disable=SC1090
. "$ENV_FILE"
set +a
: "${BORG_PREFIX:?BORG_PREFIX absent du .env}"
: "${BORG_REPO:?BORG_REPO absent du .env}"
: "${BORG_PASSPHRASE:?BORG_PASSPHRASE absent du .env}"

SSH_KEY="$SCRIPT_DIR/.ssh/${BORG_PREFIX}_ed25519"
[ -f "$SSH_KEY" ] && export BORG_RSH="/usr/bin/ssh -oStrictHostKeyChecking=accept-new -oIdentitiesOnly=yes -i $SSH_KEY"


#### 1. CHOIX DE L'ARCHIVE ####
dire "dernieres archives de '$BORG_PREFIX' :"
borg list --glob-archives "$BORG_PREFIX-*" --last 15 --format '  {archive}{TAB}{time:%Y-%m-%d %H:%M}{NL}' "$BORG_REPO"
DERNIERE="$(borg list --glob-archives "$BORG_PREFIX-*" --last 1 --short "$BORG_REPO")"
[ -n "$DERNIERE" ] || erreur "aucune archive dans le depot."

read -r -p "[restore] Archive a restaurer [$DERNIERE] : " ARCHIVE || true
ARCHIVE="${ARCHIVE:-$DERNIERE}"

# Le chemin du dump dans l'archive donne la racine de la stack sauvegardee
# (chemin absolu d'origine, sans le / initial).
CHEMIN_DUMP="$(borg list --format '{path}{NL}' "$BORG_REPO::$ARCHIVE" | grep -E '/scripts/dump-[^/]+/dolibarr\.sql$' | head -n1 || true)"
[ -n "$CHEMIN_DUMP" ] || erreur "pas de dump SQL dans $ARCHIVE : archive inutilisable."
RACINE="${CHEMIN_DUMP%/scripts/dump-*}"
PROFONDEUR="$(printf '%s' "$RACINE" | tr -cd '/' | wc -c)"
PROFONDEUR=$((PROFONDEUR + 1))


#### 2. CONFIRMATION ####
echo
echo "================================================================"
echo " RESTAURATION de $ARCHIVE"
echo
echo " Seront ECRASES, sans retour possible :"
echo "   - la base 'dolibarr' de l'instance $COMPOSE_PROJECT_NAME"
echo "   - $STACK_DIR/documents/"
echo "   - $STACK_DIR/custom/"
echo
echo " Tout ce qui a ete saisi depuis cette archive sera perdu."
echo " Pour garder une trace de l'etat actuel : Ctrl-C, puis make backup."
echo "================================================================"
read -r -p "[restore] Tape RESTAURER pour continuer : " REPONSE || true
[ "$REPONSE" = "RESTAURER" ] || erreur "abandon, rien n'a ete modifie."


#### 3. EXTRACTION ####
rm -rf "$TMP_DIR"
mkdir -p "$TMP_DIR"
trap 'rm -rf "$TMP_DIR"' EXIT
dire "extraction de $ARCHIVE..."
( cd "$TMP_DIR" && borg extract --strip-components "$PROFONDEUR" "$BORG_REPO::$ARCHIVE" "$RACINE" )

DUMP="$(find "$TMP_DIR/scripts" -path '*/dump-*/dolibarr.sql' | head -n1)"
[ -s "$DUMP" ] || erreur "dump introuvable apres extraction."
tail -n1 "$DUMP" | grep -q '^-- Dump completed' || erreur "dump tronque dans l'archive : restauration annulee, rien n'a ete modifie."


#### 4. ARRET DE DOLIBARR (MariaDB reste debout) ####
dire "arret de Dolibarr..."
compose stop dolibarr dolibarr-cron


#### 5. LE .ENV ####
if [ -f "$TMP_DIR/.env" ] && ! cmp -s "$TMP_DIR/.env" "$ENV_FILE"; then
  cp -p "$ENV_FILE" "$ENV_FILE.avant-restauration"
  cp -p "$TMP_DIR/.env" "$ENV_FILE"
  chmod 600 "$ENV_FILE" "$ENV_FILE.avant-restauration"
  dire ".env remplace par celui de l'archive (l'ancien : .env.avant-restauration)."
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a
fi


#### 6. LA BASE ####
dire "base : recreation et injection du dump..."
compose up -d --wait dolibarr-mariadb
compose exec -T dolibarr-mariadb sh -c 'exec mariadb -u root -p"$MARIADB_ROOT_PASSWORD" -e "
  DROP DATABASE IF EXISTS dolibarr;
  CREATE DATABASE dolibarr CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
  GRANT ALL PRIVILEGES ON dolibarr.* TO \`$MARIADB_USER\`@\`%\`;"'
compose exec -T dolibarr-mariadb sh -c 'exec mariadb -u root -p"$MARIADB_ROOT_PASSWORD" dolibarr' < "$DUMP"


#### 7. LES FICHIERS ####
dire "documents/ et custom/..."
rsync -a --delete "$TMP_DIR/documents/" "$STACK_DIR/documents/"
mkdir -p "$TMP_DIR/custom"
rsync -a --delete "$TMP_DIR/custom/" "$STACK_DIR/custom/"


#### 8. REDEMARRAGE ####
dire "redemarrage (attente du healthcheck)..."
compose up -d --wait
echo
dire "termine : $ARCHIVE restauree. https://$DOMAIN"
