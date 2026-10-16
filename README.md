# Dolibarr — dossier de mise en production

Stack Dolibarr (image officielle `dolibarr/dolibarr`) + MariaDB 11.4, derrière le
Traefik de [TraefikV3](https://github.com/CoopCodeCommun/TraefikV3), avec
sauvegarde borgwarehouse, restauration et mise à jour. Même organisation que la
stack [ghost](https://github.com/CoopCodeCommun/ghost).

Un `make` sans argument liste tout ce qu'on peut faire.

## Prérequis

- Docker + plugin `compose`, `make`, `borg`, `rsync`, `openssl`.
- Traefik en place : réseau Docker externe `frontend`, certresolver `myresolver`.
- Un enregistrement DNS A du domaine vers le serveur, **avant** le premier démarrage.

## Installation

```bash
git clone <ce dépôt> /opt/dolibarr && cd /opt/dolibarr
make env          # quelques questions ; tous les secrets sont générés
make up && make logs
```

Le premier démarrage installe la base (~1 min 30). Puis `https://<DOMAIN>`, avec
le compte admin affiché par `make env` : **changer son mot de passe tout de suite**.

À régler ensuite dans l'interface : *Configuration → Emails* (SMTP), les modules.
Dès que le module *Travaux planifiés* est actif : `make cron` (voir
[Tâches planifiées](#tâches-planifiées-cron)). Enfin `make init` pour la sauvegarde.
Une stack sans sauvegarde n'est pas en prod.

### Trois conteneurs

| Service | Rôle |
|---|---|
| `dolibarr` | Apache + PHP. Installe ou migre la base au démarrage. |
| `dolibarr-cron` | Même image, `DOLI_CRON=1` : lance les tâches planifiées toutes les 5 min. Avec ce drapeau, l'image ne démarre **ni** l'installation **ni** Apache, d'où un conteneur à part. |
| `dolibarr-mariadb` | La base, sur un réseau privé. |

### Ce qui ne doit plus jamais changer

`DOLI_INSTANCE_UNIQUE_ID` (sel de chiffrement : mots de passe SMTP, clés API…),
`MYSQL_ROOT_PASSWORD`, `MYSQL_PASSWORD`. `make env` refuse donc d'écraser un `.env`.

`DOLI_ADMIN_*` et `DOLI_COMPANY_*` ne servent qu'au premier démarrage.

### Plusieurs Dolibarr sur le même serveur

Un clone par instance, chacun avec son `.env` : `COMPOSE_PROJECT_NAME` et `DOMAIN`
doivent différer. Chaque instance a sa base, ses dossiers, son dépôt borg et sa
ligne de cron.

## Tâches planifiées (cron)

Relances, e-mails, rapports, et la tâche de nuit du module TiBillet : ce sont des
*tâches planifiées* de Dolibarr. Elles ne tournent que si quelqu'un réveille
Dolibarr régulièrement. Ici, c'est le conteneur `dolibarr-cron`.

### Comment ça marche

Toutes les 5 minutes, `dolibarr-cron` lance :

```
/var/www/scripts/cron/cron_run_jobs.php <DOLI_CRON_KEY> firstadmin
```

Dolibarr exécute alors les tâches dont l'heure est venue. Trois conditions, et
**si une seule manque, aucune tâche ne tourne, sans alerte dans l'interface** :

1. **Le module *Travaux planifiés* est actif.** Un module qui a des tâches (TiBillet)
   l'active seul. Sinon : *Configuration → Modules/Applications*.
2. **Un utilisateur est donné.** `DOLI_CRON_USER: firstadmin` dans
   `docker-compose.yml` (le premier administrateur actif). Sans lui, chaque passage
   s'arrête sur `Usage: ...`.
3. **La clé envoyée est celle de Dolibarr.** Le conteneur envoie `DOLI_CRON_KEY` du
   `.env`. Dolibarr la compare à son réglage *Configuration → Modules/Applications →
   Travaux planifiés → roue dentée → « Clé de sécurité pour l'URL de lancement des
   travaux programmés »*.

Le piège est la condition 3. Ce réglage est créé **vide** quand le module
s'active, donc après l'installation : l'image ne peut pas le remplir. Tant qu'il
est vide ou différent, chaque passage répond `securitykey ... does not match`.

### Après l'activation du module : `make cron`

`make cron` vérifie les trois conditions, et :

- si la clé de Dolibarr est **vide**, il la remplit avec `DOLI_CRON_KEY` ;
- si elle est **remplie mais différente** (changée dans l'interface), il n'écrase
  rien : copier `DOLI_CRON_KEY` du `.env` dans le réglage ci-dessus ;
- il affiche la date de la dernière tâche lancée.

Code de sortie non nul si quelque chose cloche : utilisable en monitoring, comme
`make check`.

### Vérifier que ça tourne

- `docker compose logs --tail 20 dolibarr-cron` : un bloc `cron_run_jobs.php` toutes
  les 5 minutes. `not qualified` est normal : la tâche n'est pas encore à l'heure.
- Dans Dolibarr : *Accueil → Outils d'administration → Travaux planifiés*, colonne
  de la dernière exécution.

### Changer la clé

Changer `DOLI_CRON_KEY` dans le `.env`, `make up` (le conteneur est recréé avec la
nouvelle clé), puis coller la même valeur dans le réglage de Dolibarr.

## Données

| Dossier | Contenu | Sauvegardé ? |
|---|---|---|
| `documents/` | Fichiers joints, PDF générés, `install.lock` | Oui |
| `custom/` | Modules externes | Oui |
| `db/` | Fichiers InnoDB | Non — remplacé par le dump SQL |

## Sauvegarde

- `make init` — clé SSH dédiée, dépôt sur borgwarehouse (token API *create*
  seul), passphrase, `borg init`, cron quotidien, première sauvegarde et
  vérification. Rejouable. **Mettre au coffre** : la passphrase, la clé exportée
  et l'adresse du dépôt.
- `make backup` — dump MariaDB, puis **tout le dossier** de la stack dans une
  archive (dump, `documents/`, `custom/`, `.env`, compose). Rétention : 7 jours,
  30 quotidiennes, 12 hebdomadaires, puis toutes les mensuelles.
- `make check` — dernière archive de moins de 25 h, contenu attendu, dump complet
  (`-- Dump completed`). Code de sortie non nul sinon : utilisable en monitoring.

C'est borgwarehouse qui prévient par mail si plus rien n'arrive.

## Restauration

### Sur l'instance qui tourne : `make restore`

Choix de l'archive, confirmation tapée (`RESTAURER`), puis : arrêt de Dolibarr,
base recréée depuis le dump, `documents/` et `custom/` remplacés, redémarrage.
Si le `.env` de l'archive diffère, il remplace l'actuel (gardé en
`.env.avant-restauration`) : il porte le sel et la majeure de la sauvegarde.

Tout ce qui a été saisi depuis l'archive est perdu : `make backup` avant, au besoin.

### Le serveur a brûlé

```bash
# Nouvelle clé SSH, à ajouter au dépôt depuis l'interface borgwarehouse
# (la clé d'origine n'est pas dans l'archive : pas la clé du coffre dans le coffre).
ssh-keygen -t ed25519 -N '' -f ~/.ssh/dolibarr_restore_ed25519
export BORG_REPO='ssh://borgwarehouse@…/./xxxxxxxx'   # depuis le coffre
export BORG_PASSPHRASE='…'                             # depuis le coffre
export BORG_RSH="ssh -i ~/.ssh/dolibarr_restore_ed25519 -oIdentitiesOnly=yes"

borg list                                  # choisir l'archive
borg extract "$BORG_REPO::<archive>"       # recrée le chemin d'origine, sans le / initial
cd <chemin>/dolibarr_stack                 # dossier complet, .env compris

docker compose up -d --wait dolibarr-mariadb
docker compose exec -T dolibarr-mariadb sh -c 'exec mariadb -u root -p"$MARIADB_ROOT_PASSWORD" dolibarr' \
  < scripts/dump-*/dolibarr.sql
make up
```

## Mise à jour : `make update`

Sauvegarde → `pull` → si la version change : suppression de
`documents/install.lock` (l'image ne migre la base qu'en son absence) →
redémarrage → migration du schéma par l'image → attente du healthcheck →
contrôle de la version en base et du re-verrouillage.

- **Correctifs et mineures** : `make update` suffit (`DOLIBARR_VERSION` est une
  majeure, le `pull` ramène la dernière `24.x`).
- **Majeure** : `DOLIBARR_VERSION=25` dans le `.env`, puis `make update`. **Une
  majeure à la fois** : les migrations de Dolibarr vont d'une version à la
  suivante. Le script refuse un saut de plusieurs majeures, et un retour arrière.

Les migrations ne sont pas réversibles. Si elle échoue, l'image remet d'elle-même
la base d'avant (son propre dump, `documents/backup-before-upgrade.sql`) ; le
détail est dans `documents/migration_error.html`. Sinon : `make restore`. Les
lignes « Duplicate column » de ce journal sont normales.

## Dépannage

- **`dolibarr` reste `starting`** — installation ou migration en cours :
  `make logs`. Apache ne démarre qu'à la fin.
- **Erreur de connexion à la base** — une variable `MYSQL_*` a changé depuis
  l'initialisation.
- **404 Traefik** — conteneur absent du réseau `frontend`, ou `DOMAIN` erroné.
- **Session perdue en http** — normal : le cookie est `Secure`, Dolibarr ne
  s'utilise qu'en https.
- **Aucune tâche planifiée ne tourne** — `make cron`. Dans les logs de
  `dolibarr-cron` : `does not match` = clé, `Usage:` = utilisateur.

## Développement

En local, un `docker-compose.override.yml` (lu tout seul par `docker compose`,
**hors de git**) ajoute ce qui ne concerne qu'un poste. Exemple pour le module
TiBillet :

```yaml
services:
  dolibarr:
    volumes:
      - /chemin/vers/tibillet-dolibarr:/var/www/html/custom/tibillet
    extra_hosts:
      - "lespass.tibillet.localhost:host-gateway"
  dolibarr-cron:
    volumes:
      - /chemin/vers/tibillet-dolibarr:/var/www/html/custom/tibillet
    extra_hosts:
      - "lespass.tibillet.localhost:host-gateway"
```

Les scripts (`make backup`, `update`, `restore`) n'utilisent que
`docker-compose.yml`. Après un `make update` en dev, `make up` remet l'override.
