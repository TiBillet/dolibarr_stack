#!/bin/bash
set -euo pipefail

##### INSTRUCTION
#
# Cree le .env de la stack. Lance par :  make env
#
# Pose les questions qui ne se devinent pas (nom de l'instance, domaine,
# societe, compte admin) et genere TOUS les secrets : mots de passe MariaDB,
# sel de chiffrement de Dolibarr, cle cron, mot de passe admin.
#
# Refuse d'ecraser un .env existant : ses mots de passe et son sel sont lies a
# la base deja initialisee. Les regenerer rendrait la base inaccessible et les
# donnees chiffrees illisibles.
#####

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
STACK_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$STACK_DIR/.env"

dire()   { echo "[env] $*"; }
erreur() { echo "[env] ERREUR : $*" >&2; exit 1; }
demander() {  # demander <invite> [defaut] -> reponse sur stdout
  local invite="$1" defaut="${2:-}" reponse=""
  if [ -n "$defaut" ]; then
    read -r -p "$invite [$defaut] : " reponse || true
    echo "${reponse:-$defaut}"
  else
    read -r -p "$invite : " reponse || true
    echo "$reponse"
  fi
}

[ -t 0 ] || erreur "make env est interactif : lance-le depuis un terminal."
command -v openssl >/dev/null || erreur "openssl introuvable dans le PATH."

if [ -f "$ENV_FILE" ]; then
  erreur ".env existe deja. Il est lie a la base initialisee : je n'y touche pas.
       Pour repartir de zero (base VIDE uniquement), supprime-le a la main."
fi


#### QUESTIONS ####
echo
dire "Creation du .env de la stack Dolibarr."
echo

PROJET="$(demander "Nom de l'instance (unique sur le serveur)" "$(basename "$STACK_DIR" | tr '[:upper:]_' '[:lower:]-')")"
case "$PROJET" in
  ''|*[!a-z0-9-]*) erreur "nom invalide : minuscules, chiffres et tirets uniquement." ;;
esac

DOMAINE="$(demander "Domaine public, sans https:// (ex. erp.example.org)")"
[ -n "$DOMAINE" ] || erreur "le domaine est obligatoire."
case "$DOMAINE" in
  http*|*/*) erreur "donne le domaine seul, sans https:// ni chemin." ;;
esac

SOCIETE="$(demander "Nom de la structure" "Ma structure")"
PAYS="$(demander "Code pays sur deux lettres" "FR")"
ADMIN="$(demander "Identifiant du compte admin" "admin")"
VERSION="$(demander "Majeure de Dolibarr" "24")"


#### ECRITURE ####
ADMIN_MDP="$(openssl rand -base64 18 | tr -d '/+=')"

# umask : le .env ne doit jamais exister, meme une milliseconde, en lecture pour tous.
umask 077
cat > "$ENV_FILE" <<EOF
# .env de la stack Dolibarr — cree par make env le $(date +%Y-%m-%d).
# Voir env_example pour le role de chaque variable.

COMPOSE_PROJECT_NAME=$PROJET
DOMAIN='$DOMAINE'
DOLIBARR_VERSION=$VERSION

# NE PLUS JAMAIS CHANGER les quatre valeurs suivantes.
DOLI_INSTANCE_UNIQUE_ID=$(openssl rand -hex 32)
MYSQL_ROOT_PASSWORD=$(openssl rand -hex 32)
MYSQL_PASSWORD=$(openssl rand -hex 32)
DOLI_CRON_KEY=$(openssl rand -hex 16)

# Lus au premier demarrage seulement.
DOLI_ADMIN_LOGIN=$ADMIN
DOLI_ADMIN_PASSWORD='$ADMIN_MDP'
DOLI_COMPANY_NAME="$SOCIETE"
DOLI_COMPANY_COUNTRYCODE=$PAYS

WWW_USER_ID=$(id -u)
WWW_GROUP_ID=$(id -g)
EOF

mkdir -p "$STACK_DIR/documents" "$STACK_DIR/custom"

echo
dire ".env cree (droits 600)."
dire "Compte admin : $ADMIN / $ADMIN_MDP"
dire "  -> a changer dans l'interface apres la premiere connexion."
echo
dire "Suite :  make up && make logs     (installation ~1 min 30)"
dire "         puis https://$DOMAINE"
dire "         puis make init           (sauvegarde)"
