#!/bin/bash
set -euo pipefail

##### INSTRUCTION
#
# Sauvegarde de la stack Dolibarr vers un depot borgwarehouse (BWH).
# Lance par :  make backup   (et par le cron pose par make init)
#
# Principe : dump MariaDB coherent depose dans scripts/, puis TOUT le dossier de
# la stack part dans UNE archive borg : le dump, documents/ (fichiers joints,
# PDF), custom/ (modules), le .env et le docker-compose.yml. Une archive suffit
# a remonter l'instance de zero, et tout y est coherent au meme instant.
#
# Exclusions :
#   db/                fichiers InnoDB — copies a chaud = base corrompue. Le dump
#                      SQL est la seule forme fiable.
#   scripts/.ssh/      la cle privee du depot : pas la cle du coffre dans le coffre
#   restauration-tmp/  zone de travail de make restore
#   .git/              deja sur GitHub
#
# Aucun secret ici : BORG_PREFIX, BORG_REPO et BORG_PASSPHRASE viennent du .env
# (ecrits par make init). Le mot de passe root MariaDB est lu DANS le conteneur.
#####

## Surveillance optionnelle via Sentry :
## Installez : curl -sL https://sentry.io/get-cli/ | bash   (maj : sentry-cli update)
# export SENTRY_DSN=''
# eval "$(sentry-cli bash-hook)"


SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
STACK_DIR="${STACK_DIR:-$(dirname "$SCRIPT_DIR")}"
COMPOSE_FILE="$STACK_DIR/docker-compose.yml"
ENV_FILE="$STACK_DIR/.env"

[ -f "$ENV_FILE" ] || { echo "[dolibarr-borg] .env introuvable : $ENV_FILE" >&2; exit 1; }
set -a
# shellcheck disable=SC1090
. "$ENV_FILE"
set +a

PREFIX="${BORG_PREFIX:?BORG_PREFIX absent du .env — lancer make init}"
SSH_KEY="$SCRIPT_DIR/.ssh/${PREFIX}_ed25519"
DUMP_DIR="$SCRIPT_DIR/dump-$PREFIX"


#### PREPARATION ####
export BORG_UNKNOWN_UNENCRYPTED_REPO_ACCESS_IS_OK=yes
export BORG_RELOCATED_REPO_ACCESS_IS_OK=yes

# Un seul backup a la fois : sinon le cron qui tombe pendant un make update
# partagerait DUMP_DIR, le premier a finir le supprime, et l'autre archive SANS
# dump, en silence.
exec 9>"$SCRIPT_DIR/.backup-$PREFIX.lock"
flock -n 9 || { echo "[dolibarr-borg] une sauvegarde est deja en cours — abandon." >&2; exit 1; }

: "${BORG_REPO:?BORG_REPO absent du .env}"
: "${BORG_PASSPHRASE:?BORG_PASSPHRASE absent du .env}"
for outil in borg docker flock; do
  command -v "$outil" >/dev/null || { echo "[dolibarr-borg] $outil introuvable dans le PATH" >&2; exit 1; }
done
[ -f "$COMPOSE_FILE" ] || { echo "[dolibarr-borg] compose introuvable : $COMPOSE_FILE" >&2; exit 1; }

DATE_NOW=$(date +%Y-%m-%d-%H-%M-%S)

# Force l'usage de CETTE cle (et pas une autre de l'agent SSH).
if [ -f "$SSH_KEY" ]; then
  chmod 600 "$SSH_KEY" 2>/dev/null || true
  export BORG_RSH="/usr/bin/ssh -oStrictHostKeyChecking=accept-new -oIdentitiesOnly=yes -i $SSH_KEY"
fi


#### DUMP MARIADB ####
trap 'rm -rf "$DUMP_DIR"' EXIT
rm -rf "$DUMP_DIR"
mkdir -p "$DUMP_DIR"
DUMP_FILE="$DUMP_DIR/dolibarr.sql"

echo "$DATE_NOW dump de la base 'dolibarr' (transaction unique)"
# --single-transaction : dump coherent sans bloquer Dolibarr (InnoDB).
docker compose -f "$COMPOSE_FILE" exec -T dolibarr-mariadb \
  sh -c 'exec mariadb-dump -u root -p"$MARIADB_ROOT_PASSWORD" \
      --single-transaction --quick --routines --triggers dolibarr' \
  > "$DUMP_FILE"

# Garde-fou : un dump sans sa derniere ligne est tronque, on n'archive pas.
if ! tail -n1 "$DUMP_FILE" | grep -q '^-- Dump completed'; then
  echo "[dolibarr-borg] dump incomplet ($DUMP_FILE) — abandon" >&2
  exit 1
fi


#### BORG CREATE ####
echo "$DATE_NOW creation de l'archive borg (dossier complet de la stack)"
/usr/bin/borg create -vs --compression lz4 \
  --exclude "$STACK_DIR/db" \
  --exclude "$STACK_DIR/scripts/.ssh" \
  --exclude "$STACK_DIR/restauration-tmp" \
  --exclude "$STACK_DIR/.git" \
  "$BORG_REPO::$PREFIX-$DATE_NOW" \
  "$STACK_DIR"

echo "$DATE_NOW prune des anciennes archives :"
# --glob-archives : le prune ne touche QUE les archives de cette stack.
/usr/bin/borg prune -v --list \
  --glob-archives "$PREFIX-*" \
  --keep-within=7d --keep-daily=30 --keep-weekly=12 --keep-monthly=-1 --keep-yearly=-1 \
  "$BORG_REPO"

echo "$DATE_NOW termine"
