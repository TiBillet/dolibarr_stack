# Table des matieres de la stack. La logique vit dans scripts/.
.PHONY: help env up down restart logs ps init backup check restore update

DC := docker compose

help:
	@echo "Stack Dolibarr — cibles disponibles :"
	@echo ""
	@echo "  make env       cree le .env (quelques questions, secrets generes)"
	@echo "  make up        demarre la stack"
	@echo "  make down      arrete la stack (les donnees restent dans documents/, custom/ et db/)"
	@echo "  make restart   redemarre la stack"
	@echo "  make logs      suit les logs de Dolibarr"
	@echo "  make ps        etat des conteneurs (healthy ?)"
	@echo ""
	@echo "  make init      configure la sauvegarde borg (cle SSH, depot BWH, cron quotidien)"
	@echo "  make backup    lance une sauvegarde maintenant"
	@echo "  make check     verifie que la derniere sauvegarde est restaurable"
	@echo "  make restore   restaure une archive (ECRASE la base, documents/ et custom/)"
	@echo ""
	@echo "  make update    sauvegarde, puis met Dolibarr a jour (migration de schema comprise)"

env:
	@bash scripts/init_env.sh

up:
	$(DC) up -d

down:
	$(DC) down

restart:
	$(DC) restart

logs:
	$(DC) logs -f dolibarr

ps:
	$(DC) ps

init:
	@bash scripts/init_backup.sh

backup:
	@bash scripts/backup_dolibarr.sh

check:
	@bash scripts/check_backup.sh

restore:
	@bash scripts/restore_dolibarr.sh

update:
	@bash scripts/update_dolibarr.sh
