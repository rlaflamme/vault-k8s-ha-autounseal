.PHONY: all
all: help

##@ General

# The help target prints out all targets with their descriptions organized
# beneath their categories. The categories are represented by '##@' and the
# target descriptions by '##'. The awk commands is responsible for reading the
# entire set of makefiles included in this invocation, looking for lines of the
# file as xyz: ## something, and then pretty-format the target and help. Then,
# if there's a line with ##@ something, that gets pretty-printed as a category.
# More info on the usage of ANSI control characters for terminal formatting:
# https://en.wikipedia.org/wiki/ANSI_escape_code#SGR_parameters
# More info on the awk command:
# http://linuxcommand.org/lc3_adv_awk.php

.PHONY: help
help: ## Display this help.
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z_0-9-]+:.*?##/ { printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)
##@ Main

.PHONY: deploy
deploy: deploy-vault-transit-cluster deploy-vault-server-cluster ## Deploy Vault tramsit cluster and Vault server cluster
	@rm -f vault-transit-token.json vault-transit-keys.json vault-recovery-keys.json

.PHONY: deploy-vault-transit-cluster
deploy-vault-transit-cluster: cleanup-workspace \
	transit-cleanup transit-init transit-unseal \
	transit-status transit-raft-list-peers \
	transit-enable-transit \
	transit-configure-auto-unseal-key transit-configure-auto-unseal-policy \
	create-transit-token

.PHONY: deploy-vault-server-cluster
deploy-vault-server-cluster: vault-cleanup vault-init vault-status vault-raft-list-peers 

.PHONY: transit-cleanup
transit-cleanup:
	@-for POD in $(TRANSIT-PODS); do \
	  kubectl exec $$POD -n hashicorp -- rm -rf /vault/data/ ;\
	done ; 
	@for POD in $(TRANSIT-PODS); do \
	  kubectl delete pod $$POD -n hashicorp ;\
	done ;
	@sleep 5

.PHONY: transit-init
transit-init:
	@-kubectl exec $(TRANSIT-POD-0) -n hashicorp -- vault operator init \
          -key-shares=4 \
          -key-threshold=2 \
          -format=json > vault-transit-keys.json
	@-kubectl exec $(TRANSIT-POD-0) -n hashicorp -- vault status
	@-kubectl delete secret vault-transit-keys -n hashicorp
	@kubectl create secret generic vault-transit-keys --from-file=vault-transit-keys.json -n hashicorp

.PHONY: transit-unseal
transit-unseal:
	@for POD in $(TRANSIT-POD-0); do \
	  for i in {0..1}; do \
	    kubectl exec $$POD -n hashicorp -- vault operator unseal $$(cat vault-transit-keys.json | jq -r .unseal_keys_b64[$$i]) ;\
	  done ;\
	done ;
	@for POD in $(TRANSIT-PODS-1-2); do \
	  kubectl exec $$POD -n hashicorp -- vault operator raft join http://$(TRANSIT-POD-0).vault-transit-internal:8200 ;\
	  for i in {0..1}; do \
	    kubectl exec $$POD -n hashicorp -- vault operator unseal $$(cat vault-transit-keys.json | jq -r .unseal_keys_b64[$$i]) ;\
	  done ;\
	done

.PHONY: transit-status
transit-status:
	@for POD in $(TRANSIT-PODS); do \
	  kubectl exec $$POD -n hashicorp -- vault status ;\
	done

.PHONY: transit-raft-list-peers
transit-raft-list-peers:
	@for POD in $(TRANSIT-PODS); do \
	  kubectl exec $$POD -n hashicorp -- sh -c "VAULT_TOKEN=$$(cat vault-transit-keys.json | jq -r .root_token) vault operator raft list-peers" ;\
	done

.PHONY: transit-enable-transit
transit-enable-transit:
	@kubectl exec $(TRANSIT-POD-0) -n hashicorp -- sh -c "VAULT_TOKEN=$$(cat vault-transit-keys.json | jq -r .root_token) vault secrets enable transit"

.PHONY: transit-configure-auto-unseal-key
transit-configure-auto-unseal-key:
	@kubectl exec $(TRANSIT-POD-0) -n hashicorp -- sh -c "VAULT_TOKEN=$$(cat vault-transit-keys.json | jq -r .root_token) vault write -f transit/keys/autounseal"

.PHONY: transit-configure-auto-unseal-policy
transit-configure-auto-unseal-policy:
	@kubectl cp files/autounseal-policy.hcl vault-transit-0:/tmp/. -n hashicorp
	@kubectl exec $(TRANSIT-POD-0) -n hashicorp -- sh -c "VAULT_TOKEN=$$(cat vault-transit-keys.json | jq -r .root_token) vault policy write autounseal /tmp/autounseal-policy.hcl"

.PHONY: create-transit-token
create-transit-token: 
	@kubectl exec $(TRANSIT-POD-0) -n hashicorp -- sh -c "VAULT_TOKEN=$$(cat vault-transit-keys.json | jq -r .root_token) vault token create -orphan -policy=autounseal -period=24h -format=json" > vault-transit-token.json
	@-kubectl delete secret transit-vault-token -n hashicorp
	@kubectl create secret generic transit-vault-token --from-literal=token=$$(jq -r .auth.client_token vault-transit-token.json) -n hashicorp


.PHONY: vault-cleanup
vault-cleanup: 
	@-for POD in $(VAULT-PODS); do \
	  kubectl exec $$POD -n hashicorp -- rm -rf /vault/data/ ;\
       	done ;
	@for POD in $(VAULT-PODS); do \
	  kubectl delete pod $$POD -n hashicorp ;\
	done ;
	@sleep 5

.PHONY: vault-init
vault-init:
	@kubectl exec $(VAULT-POD-0) -n hashicorp -- vault operator init -format=json > vault-recovery-keys.json
	@kubectl exec $(VAULT-POD-0) -n hashicorp -- vault status
	@-kubectl delete secret vault-recovery-keys -n hashicorp
	@kubectl create secret generic vault-recovery-keys --from-file=vault-recovery-keys.json -n hashicorp
	@for POD in $(VAULT-PODS-1-2); do \
	  kubectl exec $$POD -n hashicorp -- vault operator raft join http://$(VAULT-POD-0).vault-server-internal:8200 ;\
	done ;
	@sleep 5

.PHONY: vault-status
vault-status:
	@for POD in $(VAULT-PODS); do \
	  kubectl exec $$POD -n hashicorp -- vault status ;\
	done

.PHONY: vault-raft-list-peers
vault-raft-list-peers:
	@for POD in $(VAULT-PODS); do \
	  kubectl exec $$POD -n hashicorp -- sh -c "VAULT_TOKEN=$$(cat vault-recovery-keys.json | jq -r .root_token) vault operator raft list-peers" ;\
	done

.PHONY: cleanup-workspace
cleanup-workspace:
	@rm -f vault-transit-token.json vault-transit-keys.json vault-recovery-keys.json

##@ Maintenance

.PHONY: download-keys
download-keys: cleanup-workspace
	@kubectl get secret vault-transit-keys -o yaml  -o jsonpath='{.data.vault-transit-keys\.json}' -n hashicorp | base64 -d > vault-transit-keys.json
	@kubectl get secret vault-recovery-keys -o yaml  -o jsonpath='{.data.vault-recovery-keys\.json}' -n hashicorp | base64 -d > vault-recovery-keys.json

.PHONY: transit-re-unseal
transit-re-unseal: download-keys  #### Force re-unseal Vault transit cluster
	@for POD in $(TRANSIT-PODS); do \
	  for i in {0..1}; do \
	    kubectl exec $$POD -n hashicorp -- vault operator unseal $$(cat vault-transit-keys.json | jq -r .unseal_keys_b64[$$i]) ;\
	  done ;\
	done ;
	@rm -f vault-transit-token.json vault-transit-keys.json vault-recovery-keys.json

.PHONY: transit-cluster-raft-list-peers
transit-cluster-raft-list-peers: download-keys ### List Vault Transit cluster raft peers
	@for POD in $(TRANSIT-PODS); do \
	  kubectl exec $$POD -n hashicorp -- sh -c "VAULT_TOKEN=$$(cat vault-transit-keys.json | jq -r .root_token) vault operator raft list-peers" ;\
	done ;
	@rm -f vault-transit-token.json vault-transit-keys.json vault-recovery-keys.json

.PHONY: vault-cluster-raft-list-peers 
vault-cluster-raft-list-peers: download-keys ### List Vault Server cluster raft peers 
	@for POD in $(VAULT-PODS); do \
	  kubectl exec $$POD -n hashicorp -- sh -c "VAULT_TOKEN=$$(cat vault-recovery-keys.json | jq -r .root_token) vault operator raft list-peers" ;\
	done ;
	@rm -f vault-transit-token.json vault-transit-keys.json vault-recovery-keys.json


VAULT-PODS = vault-server-0 vault-server-1 vault-server-2
VAULT-POD-0 = vault-server-0
VAULT-PODS-1-2 = vault-server-1 vault-server-2
TRANSIT-PODS = vault-transit-0 vault-transit-1 vault-transit-2
TRANSIT-POD-0 = vault-transit-0
TRANSIT-PODS-1-2 = vault-transit-1 vault-transit-2
