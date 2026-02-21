# Ansible K8s Cluster (Cilium + kube-vip)

Deploys a 3-node kubeadm cluster on Arch Linux VMs with Cilium CNI, kube-vip, WireGuard tunnel, and FluxCD.

## Prerequisites

- 3 Arch Linux VMs provisioned via `terraform-proxmox`
- HashiCorp Vault instance (this repo expects `vault.apps.okd.benrachmiel.org`)
- `python-hvac` installed on the Ansible controller (`sudo pacman -S python-hvac` on Arch)
- Ansible collections:
  ```
  ansible-galaxy collection install community.general ansible.posix community.hashi_vault
  ```

## Vault Setup

### 1. Enable KV v2 secrets engine

```bash
vault secrets enable -path=secret kv-v2
```

### 2. Generate and store WireGuard keys

```bash
WG_NODE1_PRIV=$(wg genkey); WG_NODE1_PUB=$(echo "$WG_NODE1_PRIV" | wg pubkey)
WG_NODE2_PRIV=$(wg genkey); WG_NODE2_PUB=$(echo "$WG_NODE2_PRIV" | wg pubkey)
WG_NODE3_PRIV=$(wg genkey); WG_NODE3_PUB=$(echo "$WG_NODE3_PRIV" | wg pubkey)
WG_EC2_PRIV=$(wg genkey); WG_EC2_PUB=$(echo "$WG_EC2_PRIV" | wg pubkey)

vault kv put secret/wireguard/keys \
  node1_private="$WG_NODE1_PRIV" \
  node1_public="$WG_NODE1_PUB" \
  node2_private="$WG_NODE2_PRIV" \
  node2_public="$WG_NODE2_PUB" \
  node3_private="$WG_NODE3_PRIV" \
  node3_public="$WG_NODE3_PUB" \
  ec2_private="$WG_EC2_PRIV" \
  ec2_public="$WG_EC2_PUB"
```

### 3. Generate and store Kubernetes PKI

Generate CA certs and service account keys on any machine with `kubeadm`:

```bash
WORKDIR=$(mktemp -d)

kubeadm init phase certs ca --cert-dir="$WORKDIR"
kubeadm init phase certs front-proxy-ca --cert-dir="$WORKDIR"
kubeadm init phase certs etcd-ca --cert-dir="$WORKDIR"
kubeadm init phase certs sa --cert-dir="$WORKDIR"

vault kv put secret/k8s/pki \
  ca_crt=@"$WORKDIR/ca.crt" \
  ca_key=@"$WORKDIR/ca.key" \
  sa_pub=@"$WORKDIR/sa.pub" \
  sa_key=@"$WORKDIR/sa.key" \
  front_proxy_ca_crt=@"$WORKDIR/front-proxy-ca.crt" \
  front_proxy_ca_key=@"$WORKDIR/front-proxy-ca.key" \
  etcd_ca_crt=@"$WORKDIR/etcd/ca.crt" \
  etcd_ca_key=@"$WORKDIR/etcd/ca.key"

rm -rf "$WORKDIR"
```

### 4. Store GitHub PAT for FluxCD

```bash
vault kv put secret/flux/github-token \
  token="ghp_your_github_pat_here"
```

### 5. Create Vault policies

Policy files are in `vault/`. Load them:

```bash
vault policy write ansible vault/ansible.hcl
vault policy write external-secrets vault/external-secrets.hcl
```

### 6. Create an Ansible token

```bash
vault token create -policy=ansible -period=1h
```

Steps 1-6 are all that's needed to run playbooks 01-06 (cluster without Flux).

### 7. Secrets for Flux-managed workloads

Flux bootstraps the [flux-k8s-homelab](https://github.com/BenRachmiel/flux-k8s-homelab) repo, which deploys external-secrets, cert-manager, MinIO, and other workloads. Those workloads pull secrets from Vault via a `ClusterSecretStore` using JWT auth.

Populate the secrets they expect:

```bash
# Cloudflare API token (used by cert-manager for DNS01 challenges)
vault kv put secret/cloudflare/api-token \
  token="your-cloudflare-api-token"

# MinIO root credentials
vault kv put secret/minio/credentials \
  root_user="admin" \
  root_password="$(openssl rand -base64 24)"
```

### 8. Enable JWT auth (for external-secrets in-cluster)

The flux repo's `ClusterSecretStore` uses JWT auth with the cluster's SA signing key.
Run this after the cluster is up (after playbook 06):

```bash
vault auth enable -path=jwt jwt

vault kv get -field=sa_pub secret/k8s/pki > /tmp/sa.pub
vault write auth/jwt/config jwt_validation_pubkeys=@/tmp/sa.pub
rm /tmp/sa.pub

vault write auth/jwt/role/apps \
  role_type=jwt \
  bound_audiences="https://kubernetes.default.svc.cluster.local" \
  user_claim=sub \
  bound_subject="system:serviceaccount:external-secrets:vault-auth" \
  policies=external-secrets \
  ttl=1h
```

## Cluster Setup

1. Fill in `inventory.ini` with VM IPs from `terraform output`:
   ```ini
   [cp_init]
   arch-1 ansible_host=192.168.1.X wg_ip=10.10.0.11

   [cp_join]
   arch-2 ansible_host=192.168.1.X wg_ip=10.10.0.12
   arch-3 ansible_host=192.168.1.X wg_ip=10.10.0.13
   ```

2. Export Vault token:
   ```
   export VAULT_TOKEN=<ansible-scoped-token>
   ```

## Usage

Run everything (cluster + Flux bootstrap):

```
ansible-playbook playbooks/site.yml
```

Run just the cluster (no Flux). Only requires Vault steps 1-6:

```
ansible-playbook playbooks/site.yml --skip-tags flux
```

Run without Vault entirely (no WireGuard, no PKI pre-seeding, no Flux — kubeadm generates its own certs):

```
ansible-playbook playbooks/site.yml --skip-tags vault
```

Or run individual phases:

```
ansible-playbook playbooks/01-common.yml
ansible-playbook playbooks/02-wireguard.yml
ansible-playbook playbooks/03-k8s-prereqs.yml
ansible-playbook playbooks/04-init-cluster.yml
ansible-playbook playbooks/05-join-nodes.yml
ansible-playbook playbooks/06-post-cluster.yml
ansible-playbook playbooks/07-bootstrap-flux.yml   # requires Vault steps 7-8
```

## Playbook Order

| Playbook | Hosts | What it does | Vault steps required |
|----------|-------|-------------|----------------------|
| 01-common | all | Kernel modules, sysctl, swap off, base packages | — |
| 02-wireguard | all | WireGuard tunnel to EC2 (keys from Vault) | 1-2 |
| 03-k8s-prereqs | all | containerd, kubeadm, kubelet, kubectl | — |
| 04-init-cluster | cp_init | kubeadm init, kube-vip, Cilium install | 3 |
| 05-join-nodes | cp_join | kubeadm join remaining control plane nodes | — |
| 06-post-cluster | cp_init | Remove taints, validate nodes + Cilium | — |
| 07-bootstrap-flux | cp_init | FluxCD bootstrap to GitHub repo | 4, 7-8 |

Flux pulls in external-secrets, cert-manager, MinIO, and other workloads from the
[flux-k8s-homelab](https://github.com/BenRachmiel/flux-k8s-homelab) repo. Those
workloads use a `ClusterSecretStore` to fetch secrets from Vault at runtime, which
is why steps 7-8 must be completed before (or shortly after) running playbook 07.

## Output

After a successful run:
- `kubeconfig.yml` is saved in the project root
- Use it with: `export KUBECONFIG=$(pwd)/kubeconfig.yml`

## Teardown

On the VMs this is just `kubeadm reset` — or destroy and recreate the VMs with Terraform since the cluster is ephemeral.
