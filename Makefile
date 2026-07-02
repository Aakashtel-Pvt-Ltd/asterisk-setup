# asterisk-deploy — rebuild the "Aakashtel" call-center PBX on a fresh host.
# Reference server: Ubuntu 24.04, Asterisk 22.10.0 (source build), behind NAT.
# Usage: cp .env.example .env && edit .env && sudo make deploy

SHELL := /bin/bash
ENV_FILE ?= .env

# Load .env if present (export all vars to the recipe environment)
ifneq (,$(wildcard ./$(ENV_FILE)))
include $(ENV_FILE)
export
endif

SCRIPTS := ./scripts

.DEFAULT_GOAL := help

.PHONY: help check backup install configure firewall fail2ban deploy verify all

help: ## Show this help
	@echo "asterisk-deploy targets:"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'
	@echo
	@echo "Typical run:  cp .env.example .env  &&  \$$EDITOR .env  &&  sudo make deploy"

check: ## Preflight: root, OS, .env present, connectivity
	@test "$$(id -u)" = "0" || { echo "ERROR: run as root (sudo)"; exit 1; }
	@test -f $(ENV_FILE) || { echo "ERROR: $(ENV_FILE) missing (cp .env.example .env)"; exit 1; }
	@. /etc/os-release; echo "OS: $$PRETTY_NAME"; \
		case "$$ID" in ubuntu|debian) : ;; *) echo "WARN: kit tuned for Ubuntu/Debian";; esac
	@command -v envsubst >/dev/null || { echo "ERROR: gettext-base (envsubst) required"; exit 1; }
	@echo "Preflight OK."

backup: check ## Snapshot existing /etc/asterisk before any change
	$(SCRIPTS)/backup_existing_config.sh

install: check ## Build Asterisk from source + install PHP/Node app deps
	$(SCRIPTS)/install_packages.sh

configure: check ## Render templates -> /etc/asterisk (envsubst)
	$(SCRIPTS)/configure_asterisk.sh

firewall: check ## Apply nftables default-deny + allow-lists
	$(SCRIPTS)/configure_firewall.sh

fail2ban: check ## Install asterisk + sshd jails
	$(SCRIPTS)/configure_fail2ban.sh

deploy: backup install configure firewall fail2ban ## Full sequence (no service restart)
	@echo "Deploy complete. Review, then: systemctl enable --now asterisk"
	@echo "Then run: make verify"

verify: check ## Check registration, ports, and log health
	$(SCRIPTS)/verify.sh

all: deploy verify ## deploy + verify
