#!/bin/bash
set -euo pipefail

##### INSTRUCTION
#
# Configure la sauvegarde borg de cette stack Dolibarr vers un serveur
# borgwarehouse (BWH). Lance par :  make init
#
# Enchaine : cle SSH dediee -> creation du depot sur BWH -> ecriture du .env ->
# borg init -> export de la cle -> cron -> premiere sauvegarde -> verification.
#
# REJOUABLE. Le seul cas ou ce script refuse de continuer, c'est quand le depot
# configure contient DEJA DES ARCHIVES : regenerer une passphrase les rendrait
# definitivement illisibles. Dans tous les autres cas (API injoignable, borg
# init rate, Ctrl-C en plein milieu), on peut le relancer : il reprend ce qui
# existe deja au lieu de l'ecraser.
#
# TOKEN BWH : ce script ne fait QU'UN appel a l'API — le POST qui cree le depot.
# Un token avec la seule permission "create" suffit (Account > Integrations).
# Tout le reste (init, create, prune, list) passe par SSH avec la cle dediee.
#
# Genere donc un token CREATE-ONLY : s'il fuite, il ne permet ni de lister ni de
# supprimer tes depots — au pire d'en creer des parasites. Le script ne le stocke
# nulle part de toute facon. Il est saisi au clavier, ou passe le temps d'une
# execution :   BW_API_TOKEN=xxx make init
#####

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
STACK_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$STACK_DIR/.env"

BW_API_URL_DEFAUT="https://borgwarehouse.codecommun.coop"
BW_SSH_PORT_DEFAUT="2226"

dire()   { echo "[init] $*"; }
erreur() { echo "[init] ERREUR : $*" >&2; exit 1; }
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


#### PREREQUIS ####
[ -t 0 ] || erreur "make init est interactif : lance-le depuis un terminal."
[ -f "$ENV_FILE" ] || erreur ".env introuvable. Commence par :  cp env_example .env"

for outil in borg ssh-keygen openssl curl crontab; do
  command -v "$outil" >/dev/null || erreur "$outil introuvable dans le PATH."
done

# Ce que le .env dit deja (une ligne commentee ne compte pas).
valeur_env() { sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$ENV_FILE" | tail -n1 | tr -d "'\""; }
PROJET="$(valeur_env COMPOSE_PROJECT_NAME)"
BORG_PREFIX="$(valeur_env BORG_PREFIX)"
BORG_REPO="$(valeur_env BORG_REPO)"
BORG_PASSPHRASE="$(valeur_env BORG_PASSPHRASE)"


#### GARDE-FOU : ne jamais rendre des archives existantes illisibles ####
# La vraie question n'est pas "le .env est-il rempli ?" mais "y a-t-il des
# archives a proteger ?". Un .env rempli mais un depot vide, c'est un init
# precedent qui s'est arrete en route : on doit pouvoir reprendre.
REPRISE=0
if [ -n "$BORG_REPO" ] && [ -n "$BORG_PASSPHRASE" ]; then
  dire "une configuration existe deja dans le .env — je regarde le depot..."
  CLE_EXISTANTE="$SCRIPT_DIR/.ssh/${BORG_PREFIX}_ed25519"
  [ -f "$CLE_EXISTANTE" ] && export BORG_RSH="/usr/bin/ssh -oStrictHostKeyChecking=accept-new -oIdentitiesOnly=yes -i $CLE_EXISTANTE"

  if ARCHIVES="$(BORG_PASSPHRASE="$BORG_PASSPHRASE" borg list --short "$BORG_REPO" 2>/dev/null)" && [ -n "$ARCHIVES" ]; then
    NB="$(printf '%s\n' "$ARCHIVES" | wc -l)"
    echo >&2
    echo "[init] Le depot contient deja $NB archive(s)." >&2
    echo >&2
    echo "  Ce script s'arrete ici, VOLONTAIREMENT." >&2
    echo "  Regenerer une passphrase rendrait ces archives DEFINITIVEMENT" >&2
    echo "  ILLISIBLES — y compris celles deja envoyees chez BWH." >&2
    echo >&2
    echo "  Pour verifier la sauvegarde en place :   make check" >&2
    echo "  Pour en refaire une de zero : cree un nouveau depot sur BWH et vide" >&2
    echo "  les lignes BORG_* du .env, en sachant que tu perds les archives." >&2
    exit 1
  fi

  dire "depot vide ou injoignable : je reprends la configuration la ou elle s'est arretee."
  REPRISE=1
fi


#### 1. PREFIXE ET FREQUENCE ####
echo
dire "Configuration de la sauvegarde borg de cette stack."
echo

if [ "$REPRISE" = 0 ]; then
  BORG_PREFIX="$(demander "Prefixe des archives (nomme aussi la cle SSH)" "${PROJET:-dolibarr}")"
  # Un prefixe avec des espaces casserait le nom des archives et le glob du prune.
  case "$BORG_PREFIX" in
    ''|*[!a-zA-Z0-9_-]*) erreur "prefixe invalide : lettres, chiffres, - et _ uniquement." ;;
  esac
else
  dire "prefixe repris du .env : $BORG_PREFIX"
fi

# La frequence est demandee AVANT de creer le depot : elle determine l'alerte
# BWH et le seuil de make check, qui doivent rester coherents entre eux.
echo
dire "Frequence de sauvegarde :"
echo "   1) quotidienne (recommande)"
echo "   2) horaire"
echo "   3) hebdomadaire"
echo "   4) aucune (je poserai le cron moi-meme)"
case "$(demander "Ton choix" "1")" in
  2) PLANIF="@hourly" ; ALERTE=21600  ; AGE_MAX=2   ;;
  3) PLANIF="@weekly" ; ALERTE=864000 ; AGE_MAX=169 ;;
  4) PLANIF=""        ; ALERTE=90000  ; AGE_MAX=25  ;;
  *) PLANIF="@daily"  ; ALERTE=90000  ; AGE_MAX=25  ;;
esac


#### 2. CLE SSH DEDIEE (une cle = un depot sur BWH) ####
SSH_KEY="$SCRIPT_DIR/.ssh/${BORG_PREFIX}_ed25519"
if [ -f "$SSH_KEY" ]; then
  dire "cle SSH existante reutilisee : $SSH_KEY"
else
  mkdir -p "$SCRIPT_DIR/.ssh"
  chmod 700 "$SCRIPT_DIR/.ssh"
  ssh-keygen -t ed25519 -N '' -C "borg-$BORG_PREFIX" -f "$SSH_KEY" >/dev/null
  dire "cle SSH generee : $SSH_KEY"
fi
chmod 600 "$SSH_KEY"
export BORG_RSH="/usr/bin/ssh -oStrictHostKeyChecking=accept-new -oIdentitiesOnly=yes -i $SSH_KEY"


#### 3. PASSPHRASE ####
[ -n "$BORG_PASSPHRASE" ] || BORG_PASSPHRASE="$(openssl rand -base64 32)"
export BORG_PASSPHRASE


#### 4. LE DEPOT SUR BORGWAREHOUSE ####
if [ -z "$BORG_REPO" ]; then
  echo
  dire "Creation du depot sur borgwarehouse."
  dire "Un token API automatise cette etape (Account > Integrations)."
  dire "La permission 'create' SEULE suffit : c'est le seul appel qu'on fait."
  dire "Sans token, tu creeras le depot a la main dans l'interface."
  echo

  BW_API_URL="$(demander "URL de borgwarehouse" "$BW_API_URL_DEFAUT")"
  BW_SSH_PORT="$(demander "Port SSH de borgwarehouse" "$BW_SSH_PORT_DEFAUT")"

  if [ -z "${BW_API_TOKEN:-}" ]; then
    read -r -s -p "[init] Token API BWH, permission 'create' (vide = methode manuelle) : " BW_API_TOKEN || true
    echo
  fi

  if [ -n "${BW_API_TOKEN:-}" ]; then
    QUOTA="$(demander "Quota du depot, en Go" "10")"
    dire "POST $BW_API_URL/api/v1/repositories"
    REPONSE="$(curl -sS --fail-with-body -X POST "$BW_API_URL/api/v1/repositories" \
      -H "Authorization: Bearer $BW_API_TOKEN" \
      -H "Content-Type: application/json" \
      --data-binary @- <<EOF || erreur "l'appel a l'API BWH a echoue (token invalide ? URL incorrecte ?). Tu peux relancer make init : rien n'est perdu."
{
  "alias": "$BORG_PREFIX",
  "sshPublicKey": "$(cat "${SSH_KEY}.pub")",
  "storageSize": $QUOTA,
  "comment": "Dolibarr — cree par make init",
  "alert": $ALERTE,
  "lanCommand": false,
  "appendOnlyMode": false
}
EOF
)"
    # Reponse : {"id":2,"repositoryName":"c1ddd097"}. L'adresse SSH n'y est pas :
    # elle est deterministe, on la reconstruit.
    NOM_DEPOT="$(printf '%s' "$REPONSE" | sed -n 's/.*"repositoryName"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
    [ -n "$NOM_DEPOT" ] || erreur "reponse inattendue de l'API : $REPONSE"
    HOTE_BWH="$(printf '%s' "$BW_API_URL" | sed -e 's#^https\?://##' -e 's#/.*##')"
    BORG_REPO="ssh://borgwarehouse@$HOTE_BWH:$BW_SSH_PORT/./$NOM_DEPOT"
    dire "depot cree : $NOM_DEPOT"
  else
    echo
    dire "Sur $BW_API_URL :"
    dire "  1. New repository"
    dire "  2. colle la cle publique ci-dessous"
    dire "  3. regle Alert (c'est elle qui previendra si une sauvegarde manque)"
    dire "  4. copie l'adresse SSH du depot (icone en haut a droite de sa vignette)"
    echo
    cat "${SSH_KEY}.pub"
    echo
  fi

  BORG_REPO="$(demander "Adresse SSH du depot" "$BORG_REPO")"
  case "$BORG_REPO" in
    ssh://*) : ;;
    *) erreur "adresse invalide : elle doit commencer par ssh://" ;;
  esac
else
  dire "depot repris du .env : $BORG_REPO"
fi
export BORG_REPO


#### 5. INIT DU DEPOT ####
# On ecrit le .env AVANT : si borg init echoue, la passphrase n'est pas perdue
# et make init peut etre relance (le garde-fou verra un depot sans archive).
if [ "$REPRISE" = 0 ]; then
  {
    echo ""
    echo "# Sauvegarde borg — ecrit par make init le $(date +%Y-%m-%d)"
    echo "BORG_PREFIX=$BORG_PREFIX"
    echo "BORG_REPO=$BORG_REPO"
    echo "BORG_PASSPHRASE='$BORG_PASSPHRASE'"
    echo "AGE_MAX_HEURES=$AGE_MAX"
  } >> "$ENV_FILE"
  chmod 600 "$ENV_FILE"
  dire "$ENV_FILE complete."
fi

if borg list "$BORG_REPO" >/dev/null 2>&1; then
  dire "depot deja initialise."
else
  dire "initialisation du depot (repokey-blake2)..."
  borg init -e repokey-blake2 "$BORG_REPO"
fi


#### 6. LE COFFRE-FORT ####
echo
echo "================================================================"
echo " A METTRE DANS UN COFFRE-FORT NUMERIQUE, MAINTENANT."
echo
echo " Sans ces elements, les archives sont un bloc chiffre"
echo " definitivement illisible. C'est le seul maillon que la"
echo " sauvegarde ne peut pas se sauvegarder elle-meme."
echo "================================================================"
echo
echo "Depot      : $BORG_REPO"
echo "Passphrase : $BORG_PASSPHRASE"
echo
echo "Cle du depot (borg key export) :"
echo "----------------------------------------------------------------"
borg key export "$BORG_REPO"
echo "----------------------------------------------------------------"
echo
[ "$(demander "Tape OUI quand c'est copie au coffre" "")" = "OUI" ] \
  || erreur "abandon. Le depot et le .env sont deja en place : relance make init quand tu es pret (il reprendra ici)."


#### 7. CRON ####
if [ -n "$PLANIF" ]; then
  # Le log ne va pas dans /var/log : un non-root ne peut pas y ecrire, et si la
  # redirection echoue, cron n'execute meme pas la commande — zero sauvegarde,
  # zero trace.
  LOG_FILE="$HOME/.dolibarr-backup-$BORG_PREFIX.log"
  LIGNE_CRON="$PLANIF bash $SCRIPT_DIR/backup_dolibarr.sh >> $LOG_FILE 2>&1"
  # crontab -l sort en erreur quand le crontab est vide : on absorbe.
  CRON_ACTUEL="$(crontab -l 2>/dev/null || true)"
  # On matche le chemin ABSOLU : deux stacks Dolibarr sur la meme machine ont
  # chacune leur ligne, et un grep laxiste en priverait la seconde.
  if printf '%s\n' "$CRON_ACTUEL" | grep -Fq "$SCRIPT_DIR/backup_dolibarr.sh"; then
    dire "une ligne de cron existe deja pour cette stack — inchangee."
  else
    printf '%s\n%s\n' "$CRON_ACTUEL" "$LIGNE_CRON" | grep -v '^[[:space:]]*$' | crontab -
    dire "cron pose : $LIGNE_CRON"
  fi
fi


#### 8. PREMIERE SAUVEGARDE, ET VERIFICATION ####
echo
dire "premiere sauvegarde..."
bash "$SCRIPT_DIR/backup_dolibarr.sh"
echo
dire "verification..."
bash "$SCRIPT_DIR/check_backup.sh"
echo
dire "termine. Verifie la sauvegarde quand tu veux avec : make check"
