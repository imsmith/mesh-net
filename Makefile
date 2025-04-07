VAULT_ADDR=https://127.0.0.1:8200
VAULT_TOKEN=$(shell head -c 16 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 32)
VAULT_PID_FILE=.vault.pid
VAULT_ENV_FILE=.vault.env
VAULT_LOG_FILE=.vault.log

CLEAN_DIRS=installers cloud-init
CLEAN_FILES=members.*.csv zone.*.txt $(VAULT_PID_FILE) $(VAULT_ENV_FILE) $(VAULT_LOG_FILE)

.PHONY: all clean vault-start vault-env vault-stop mesh

all: clean vault-start vault-env mesh

clean:
	@echo "Cleaning up old mesh and Vault data..."
	@rm -rf $(CLEAN_DIRS) $(CLEAN_FILES)

vault-start:
	@echo "Starting Vault dev server with TLS..."
	@VAULT_DEV_ROOT_TOKEN_ID=$(VAULT_TOKEN) vault server -dev -dev-tls -dev-root-token-id=$(VAULT_TOKEN) > $(VAULT_LOG_FILE) 2>&1 & echo $$! > $(VAULT_PID_FILE)
	@sleep 3

vault-env:
	@echo "Capturing Vault environment variables..."
	@grep 'Root CA Certificate:' $(VAULT_LOG_FILE) | awk '{print $$NF}' > .vault-ca-path
	@echo "export VAULT_ADDR=$(VAULT_ADDR)" > $(VAULT_ENV_FILE)
	@echo "export VAULT_TOKEN=$(VAULT_TOKEN)" >> $(VAULT_ENV_FILE)
	@echo "export VAULT_CACERT=$$(cat .vault-ca-path)" >> $(VAULT_ENV_FILE)
	@chmod +x $(VAULT_ENV_FILE)
	@echo "source $(VAULT_ENV_FILE)" > set-vault-env.sh
	@chmod +x set-vault-env.sh
	@echo "Vault environment saved to $(VAULT_ENV_FILE) and ./set-vault-env.sh"

vault-stop:
	@echo "Stopping Vault dev server..."
	@kill `cat $(VAULT_PID_FILE)` || true
	@rm -f $(VAULT_PID_FILE) .vault-ca-path

mesh:
	@echo "Generating mesh topology..."
	@bash ./gen-mesh.sh
