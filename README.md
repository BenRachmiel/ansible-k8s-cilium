# Ansible K8s Cluster (Cilium + kube-vip)

Deploys a 3-node kubeadm cluster on Arch Linux VMs with Cilium CNI, kube-vip, WireGuard tunnel, and FluxCD.

## Prerequisites

- 3 Arch Linux VMs provisioned via `terraform-proxmox`
- Vault running and populated with WireGuard keys, GitHub PAT, etc.
- Ansible collections installed:
  ```
  ansible-galaxy collection install community.general ansible.posix community.hashi_vault
  ```

## Setup

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

Run everything:

```
ansible-playbook playbooks/site.yml
```

Or run individual phases:

```
ansible-playbook playbooks/01-common.yml
ansible-playbook playbooks/02-wireguard.yml
ansible-playbook playbooks/03-k8s-prereqs.yml
ansible-playbook playbooks/04-init-cluster.yml
ansible-playbook playbooks/05-join-nodes.yml
ansible-playbook playbooks/06-post-cluster.yml
ansible-playbook playbooks/07-bootstrap-flux.yml
```

## Playbook Order

| Playbook | Hosts | What it does |
|----------|-------|-------------|
| 01-common | all | Kernel modules, sysctl, swap off, base packages |
| 02-wireguard | all | WireGuard tunnel to EC2 (keys from Vault) |
| 03-k8s-prereqs | all | containerd, kubeadm, kubelet, kubectl |
| 04-init-cluster | cp_init | kubeadm init, kube-vip, Cilium install |
| 05-join-nodes | cp_join | kubeadm join remaining control plane nodes |
| 06-post-cluster | cp_init | Remove taints, validate nodes + Cilium |
| 07-bootstrap-flux | cp_init | FluxCD bootstrap to GitHub repo |

## Output

After a successful run:
- `kubeconfig.yml` is saved in the project root
- Use it with: `export KUBECONFIG=$(pwd)/kubeconfig.yml`

## Teardown

On the VMs this is just `kubeadm reset` — or destroy and recreate the VMs with Terraform since the cluster is ephemeral.
