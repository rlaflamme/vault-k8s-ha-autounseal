### Vault transit
### Référence
https://dev.to/luafanti/vault-auto-unseal-using-transit-secret-engine-on-kubernetes-13k8


#### Helm install
```
helm install vault-transit hashicorp/vault -f vault-transit-helm-values.yaml

helm install vault hashicorp/vault -f vault-auto-unseal-helm-values.yaml
```

#### cleanup
```
vault_transit_PODS="vault-transit-0 vault-transit-1 vault-transit-2"
for POD in $vault_transit_PODS; do
  kubectl exec $POD -- rm -rf /vault/data/;
done

vault_transit_PODS="vault-transit-0 vault-transit-1 vault-transit-2"
for POD in $vault_transit_PODS; do
  kubectl delete pod $POD
done
```

#### init
```
kubectl exec vault-transit-0 -- vault operator init \
    -key-shares=4 \
    -key-threshold=2 \
    -format=json > vault-transit-keys.json

kubectl exec vault-transit-0 -- vault status
kubectl create secret generic vault-transit-keys --from-file=vault-transit-keys.json
```

#### (a) after init: unseal vault-transit-0
```
PODS="vault-transit-0"
for POD in $PODS; do	
  for i in {0..1}; do	
    kubectl exec $POD -- vault operator unseal $(cat vault-transit-keys.json | jq -r .unseal_keys_b64[$i])
  done
done
```

#### (a) after init: unseal vault-transit-1,vault-transit-2
```
PODS="vault-transit-1 vault-transit-2"
for POD in $PODS; do	
  kubectl exec $POD -- vault operator raft join http://vault-transit-0.vault-transit-internal:8200;
  for i in {0..1}; do	
    kubectl exec $POD -- vault operator unseal $(cat vault-transit-keys.json | jq -r .unseal_keys_b64[$i]);
  done
done
```
#### (b) after vault transit PODS restarted: unseal all vault-transits
```
PODS="vault-transit-0 vault-transit-1 vault-transit-2"
for POD in $PODS; do	
  kubectl exec $POD -- vault operator raft join http://vault-transit-0.vault-transit-internal:8200;
  for i in {0..1}; do	
    kubectl exec $POD -- vault operator unseal $(cat vault-transit-keys.json | jq -r .unseal_keys_b64[$i]);
  done
done
```

#### vault transit status
```
PODS="vault-transit-0 vault-transit-1 vault-transit-2"
for POD in $PODS; do	
  kubectl exec $POD -- vault status
done
```


#### raft: list peers

```
PODS="vault-transit-0 vault-transit-1 vault-transit-2"
for POD in $PODS; do	
  kubectl exec $POD -- sh -c "VAULT_TOKEN=$(cat vault-transit-keys.json | jq -r .root_token) vault operator raft list-peers"
done
```

#### setup enable transit and setup autounseal keys
```
kubectl exec vault-transit-0 -- sh -c "VAULT_TOKEN=$(cat vault-transit-keys.json | jq -r .root_token) vault secrets enable transit"
kubectl exec vault-transit-0 -- sh -c "VAULT_TOKEN=$(cat vault-transit-keys.json | jq -r .root_token) vault write -f transit/keys/autounseal"
```

#### setup autounseal policy file
```
cat << EOF > autounseal-policy.hcl
path "transit/encrypt/autounseal" {
   capabilities = [ "update" ]
}

path "transit/decrypt/autounseal" {
   capabilities = [ "update" ]
}
EOF
kubectl cp autounseal-policy.hcl vault-transit-0:/tmp/.
kubectl exec vault-transit-0 -- sh -c "VAULT_TOKEN=$(cat vault-transit-keys.json | jq -r .root_token) vault policy write autounseal /tmp/autounseal-policy.hcl"
```

#### create transit token to be set in a secret
```
kubectl exec vault-transit-0 -- sh -c "VAULT_TOKEN=$(cat vault-transit-keys.json | jq -r .root_token) vault token create -orphan -policy=autounseal -period=24h -format=json" > vault-transit-token.json
kubectl delete secret transit-vault-token 
kubectl create secret generic transit-vault-token --from-literal=token=$(jq -r .auth.client_token vault-transit-token.json)
```


### vault


#### cleanup
```
PODS="vault-0 vault-1 vault-2"
for POD in $PODS; do
  kubectl exec $POD -- rm -rf /vault/data/;
done
```
for i in {0..2}; do 
  kubectl delete pod vault-$i
done


#### init
```
kubectl exec vault-0 -- vault operator init -format=json > vault-recovery-keys.json
kubectl exec vault-0 -- vault status
kubectl create secret generic vault-recovery-keys --from-file=vault-recovery-keys.json
```

#### join vault-1, vault-2
```
PODS="vault-1 vault-2"
for POD in $PODS; do
  kubectl exec -ti $POD -- vault operator raft join http://vault-0.vault-internal:8200
done
```
#### vault status
```
PODS="vault-0 vault-1 vault-2"
for POD in $PODS; do	
  kubectl exec $POD -- vault status
done
```

#### raft: list peers
```
PODS="vault-0 vault-1 vault-2"
for POD in $PODS; do
  kubectl exec $POD -- sh -c "VAULT_TOKEN=$(cat vault-recovery-keys.json | jq -r .root_token) vault operator raft list-peers"
done
```

