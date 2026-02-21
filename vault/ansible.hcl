path "secret/data/wireguard/keys" {
  capabilities = ["read"]
}

path "secret/data/k8s/pki" {
  capabilities = ["read"]
}

path "secret/data/flux/github-token" {
  capabilities = ["read"]
}
