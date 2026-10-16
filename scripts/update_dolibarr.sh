#!/bin/bash
set -euo pipefail

##### INSTRUCTION
#
# Mise a jour de Dolibarr, avec sauvegarde prealable. Lance par :  make update
#
#   sauvegarde borg -> pull -> deverrouillage -> up -> migration du schema
#   par l'image -> attente du healthcheck -> verification de la version
#
# Correctifs et mineures : `make update` suffit (le tag DOLIBARR_VERSION est
# une majeure, le pull ramene la derniere 24.x).
# Majeure : changer DOLIBARR_VERSION dans le .env (24 -> 25), puis make update.
# UNE majeure a la fois : les scripts de migration de Dolibarr passent d'une
# version a la suivante, pas de 22 a 25 d'un coup. Ce script refuse le saut.
#
# Pourquoi supprimer documents/install.lock : l'image ne migre la base que si ce
# fichier est absent. Elle le recree elle-meme a la fin de la migration.
#
# Les migrations de schema NE SONT PAS reversibles : d'ou la sauvegarde avant.
# En cas d'echec, l'image restaure d'elle-meme le dump qu'elle a fait juste
# avant (documents/backup-before-upgrade.sql) ; sinon : make restore.
#
# Usage :
#   ./update_dolibarr.sh              # backup puis mise a jour
#   ./update_dolibarr.sh --no-backup  # mise a jour seule (a eviter)
#####

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
STACK_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$STACK_DIR/.env"

# Une migration de majeure peut prendre plusieurs minutes sur une grosse base.
HEALTH_TIMEOUT=900

dire()   { echo "[update] $*"; }
erreur() { echo "[update] ERREUR : $*" >&2; exit 1; }
compose() { docker compose -f "$STACK_DIR/docker-compose.yml" "$@"; }

[ -f "$ENV_FILE" ] || erreur ".env introuvable : $ENV_FILE"
set -a
# shellcheck disable=SC1090
. "$ENV_FILE"
set +a

version_image() {  # version de Dolibarr contenue dans une image
  docker image inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$1" 2>/dev/null \
    | sed -n 's/^DOLI_VERSION=//p'
}
majeure() { echo "${1%%.*}"; }


#### 1. VERSION ACTUELLE (celle de la base, pas celle de l'image) ####
VERSION_BASE="$(compose exec -T dolibarr-mariadb sh -c 'exec mariadb -u root -p"$MARIADB_ROOT_PASSWORD" dolibarr -N -e "
  SELECT value FROM llx_const
  WHERE name IN (\"MAIN_VERSION_LAST_UPGRADE\", \"MAIN_VERSION_LAST_INSTALL\") AND entity = 0
  ORDER BY INET_ATON(SUBSTRING_INDEX(value, \"-\", 1)) DESC LIMIT 1"' 2>/dev/null || true)"
[ -n "$VERSION_BASE" ] || erreur "version de la base illisible. La stack tourne-t-elle ? (make ps)"
dire "version de la base : $VERSION_BASE"


#### 2. SAUVEGARDE ####
# Avant le pull : il ramene aussi le dernier correctif de MariaDB.
if [ "${1:-}" = "--no-backup" ]; then
  dire "sauvegarde IGNOREE (--no-backup)"
else
  dire "sauvegarde avant mise a jour..."
  bash "$SCRIPT_DIR/backup_dolibarr.sh"
fi


#### 3. NOUVELLE IMAGE, ET GARDE-FOU SUR LA MAJEURE ####
IMAGE="dolibarr/dolibarr:${DOLIBARR_VERSION:-24}"
dire "recuperation de $IMAGE..."
compose pull
VERSION_IMAGE="$(version_image "$IMAGE")"
[ -n "$VERSION_IMAGE" ] || erreur "version de l'image $IMAGE illisible."
dire "version de l'image : $VERSION_IMAGE"

ECART=$(( $(majeure "$VERSION_IMAGE") - $(majeure "$VERSION_BASE") ))
if [ "$ECART" -lt 0 ]; then
  erreur "l'image ($VERSION_IMAGE) est plus ancienne que la base ($VERSION_BASE).
       Dolibarr ne sait pas redescendre. Remets DOLIBARR_VERSION=$(majeure "$VERSION_BASE") dans le .env."
fi
if [ "$ECART" -gt 1 ]; then
  erreur "saut de $ECART majeures ($VERSION_BASE -> $VERSION_IMAGE) : refuse.
       Monte une majeure a la fois : DOLIBARR_VERSION=$(( $(majeure "$VERSION_BASE") + 1 )), make update, puis la suivante."
fi

if [ "$VERSION_IMAGE" = "$VERSION_BASE" ]; then
  dire "deja a jour ($VERSION_BASE). On s'assure juste que tout tourne sur l'image recuperee."
  compose up -d --wait
  exit 0
fi


#### 4. MIGRATION ####
dire "$VERSION_BASE -> $VERSION_IMAGE : deverrouillage de la migration et redemarrage..."
rm -f "$STACK_DIR/documents/install.lock"
# dolibarr seul : `up -d` sur toute la stack attendrait son healthcheck (le cron
# en depend) et sortirait en erreur avant qu'on puisse afficher le diagnostic.
compose up -d dolibarr-mariadb dolibarr

CONTENEUR="$(compose ps -q dolibarr)"
[ -n "$CONTENEUR" ] || erreur "conteneur dolibarr introuvable"

ATTENTE=0
ETAT="inconnu"
while [ "$ATTENTE" -lt "$HEALTH_TIMEOUT" ]; do
  ETAT="$(docker inspect --format '{{.State.Health.Status}}' "$CONTENEUR" 2>/dev/null || echo 'absent')"
  [ "$ETAT" = healthy ] || [ "$ETAT" = unhealthy ] && break
  sleep 5
  ATTENTE=$((ATTENTE + 5))
done


#### 5. VERIFICATION ####
VERSION_APRES="$(compose exec -T dolibarr-mariadb sh -c 'exec mariadb -u root -p"$MARIADB_ROOT_PASSWORD" dolibarr -N -e "
  SELECT value FROM llx_const
  WHERE name IN (\"MAIN_VERSION_LAST_UPGRADE\", \"MAIN_VERSION_LAST_INSTALL\") AND entity = 0
  ORDER BY INET_ATON(SUBSTRING_INDEX(value, \"-\", 1)) DESC LIMIT 1"' 2>/dev/null || true)"

if [ "$ETAT" = healthy ] && [ "$VERSION_APRES" = "$VERSION_IMAGE" ] && [ -f "$STACK_DIR/documents/install.lock" ]; then
  compose up -d dolibarr-cron
  dire "OK — Dolibarr $VERSION_BASE -> $VERSION_APRES, en bonne sante, installation reverrouillee."
  exit 0
fi

echo "[update] ECHEC : etat $ETAT, base en version '${VERSION_APRES:-?}' (attendu $VERSION_IMAGE)." >&2
[ -f "$STACK_DIR/documents/install.lock" ] || echo "[update] ATTENTION : install.lock absent, /install est ouvert. Ne laisse pas l'instance en ligne ainsi." >&2
echo "[update] Detail de la migration : documents/migration_error.html" >&2
echo "[update] Derniers logs :" >&2
compose logs --tail 40 dolibarr >&2 || true
echo "[update] Sauvegarde d'avant la mise a jour dans borgwarehouse : make restore." >&2
exit 1
