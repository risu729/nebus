# OCI Kubernetes GitOps (nebus)

An automated, highly constrained Kubernetes deployment tailored specifically for Oracle Cloud Infrastructure's "Always Free" Tier.

## Architecture Overview

This repository uses Terraform and GitOps (Flux + Argo CD) to deploy a zero-trust, private Kubernetes cluster utilizing:
- **Talos Linux:** A secure, immutable operating system powering the Kubernetes nodes.
- **Debian Bastion:** A tiny AMD Micro instance residing in the private subnet that automatically establishes an outbound Cloudflare tunnel to allow operators secure `talosctl` and SSH access without exposing ports.
- **Private Topology:** Computes reside in a Private Subnet with outbound networking secured by a NAT Gateway, utilizing an OCI Service Gateway to reach Object Storage APIs directly.
- **GitOps Managed:** Layer 0 (Base infrastructure like Cilium CNI, OCI-CCM, and Sealed Secrets) is managed by Flux CD, handing off Layer 1 (Workloads) to Argo CD.

## Getting Started

Because Talos nodes operate within a private subnet without public IP addresses, initializing the cluster requires establishing a secure tunnel via the Bastion instance.

### 1. Configure Cloudflare Tunnel
Create a Cloudflare Zero Trust tunnel specifically for the Bastion. Extract the tunnel token. 

### 2. Supply Terraform Secrets
You need to pass your sensitive tokens to HCP Terraform securely:
- `cloudflare_api_token` (Your Cloudflare API key for creating DNS records/Ingress tunnels later)
- `bastion_cloudflare_token` (The token generated in step 1)

**Note:** If running Terraform locally, establish these as environment variables (`TF_VAR_cloudflare_api_token="..."`). 

### 3. Deploy the Infrastructure
Let HCP Terraform (or local Terraform) provision the OCI footprint. 

The Bastion instance will boot, run its `cloud-init`, download the `cloudflared` package, and connect outbound to your Cloudflare account. 

### 4. Connect to the Bastion
From your local workstation, use your Cloudflare client to proxy a connection to the Bastion:
```bash
cloudflared access ssh --hostname bastion.yourdomain.com
```

### 5. Generate Talos Secrets 
Once inside the Bastion (now residing on the same private subnet as the Talos nodes), generate the Kubernetes secrets:
```bash
talosctl gen secrets
talosctl gen config nebus https://[CONTROL_PLANE_IP]:6443
```
*Apply the specific machine configurations (`controlplane.yaml` and `worker.yaml`) directly via `talosctl apply-config` to the private node IPs.*

### 6. Bootstrap Kubernetes
Finally, command the control plane to bootstrap etcd and initialize:
```bash
talosctl --nodes [CONTROL_PLANE_IP] bootstrap
```

Flux CD will automatically begin reading from this repository to deploy the required DaemonSets, kicking off the remainder of the Layer 0 and Layer 1 syncing processes.

## Secrets Management
This repository utilizes **Sealed Secrets**. Never commit raw Kubernetes Secrets.
To encrypt a secret for GitOps, use the `kubeseal` CLI (managed by `mise` in this repository):

```bash
kubeseal -o yaml < raw-secret.yaml > sealed-secret.yaml
```
