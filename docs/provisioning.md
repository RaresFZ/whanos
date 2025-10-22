---
title: Whanos Infrastructure Provisioning
---

## Overview

The Ansible project under `ansible/` automates installation of every major Whanos component:

| Role          | Responsibilities                                                                                             |
|---------------|---------------------------------------------------------------------------------------------------------------|
| `jenkins`     | Installs Docker engine, provisions Jenkins via Configuration-as-Code, seeds the Whanos pipeline job, and installs required plugins. |
| `registry`    | Deploys a hardened Docker registry behind Caddy with TLS and HTTP basic authentication.                      |
| `kubernetes`  | Builds a kubeadm-based cluster with containerd, initialises the control plane, joins ≥2 worker nodes, and installs the Calico CNI. |

## Prerequisites

- Ubuntu/Debian hosts with passwordless sudo for the `ansible_user` (default `deploy`).
- SSH access with keys configured in your Ansible environment.
- Python 3.9+ and `ansible-core 2.15+` on the control machine.
- Required collections:
  ```bash
  ansible-galaxy collection install community.general community.docker
  ```
- Access to the infrastructure repository on the control machine.

## Inventory layout

Edit `ansible/inventory/hosts.yml` and replace the placeholder hostnames with your actual machines. Example:

```yaml
jenkins:
  hosts:
    jenkins1:
      ansible_host: ci.whanos.example.com
registry:
  hosts:
    registry1:
      ansible_host: registry.whanos.example.com
k8s_control_plane:
  hosts:
    master:
      ansible_host: k8s-master.whanos.example.com
k8s_workers:
  hosts:
    worker-1:
      ansible_host: k8s-node1.whanos.example.com
    worker-2:
      ansible_host: k8s-node2.whanos.example.com
```

Set site-wide defaults in `group_vars/all.yml` (domain, registry hostname, timezone, etc.).

## Executing the playbook

```bash
cd ansible
ansible-playbook site.yml
```

Or run the wrapper:

```bash
./scripts/start-whanos.sh
```

The playbook performs the tasks in the following order:

1. **Jenkins host**: installs Docker, configures Jenkins via JCasC (`/var/lib/jenkins/casc_configs/whanos.yaml`), seeds the `whanos-orchestrator` pipeline, and ensures plugins are present.
2. **Registry host**: installs Docker, deploys registry + Caddy via Compose, provisions TLS (Let's Encrypt) and HTTP basic auth (`registry_users` list).
3. **Kubernetes nodes**: configures kernel prerequisites, installs containerd/kubeadm/kubelet, initialises the control plane, installs Calico, generates join commands, and joins worker nodes.

### Idempotency notes

- kubeadm initialisation is guarded by checks for `/etc/kubernetes/admin.conf`.
- Worker join commands only run if `/etc/kubernetes/kubelet.conf` is missing.
- Registry credentials are managed with `community.general.htpasswd`, avoiding repeated password prompts.
- Jenkins plugin installation and job seeding are safe to re-run; the CLI script recreates the Job DSL pipeline definition if it drifts.

## Post-provisioning validation

1. **Jenkins**: Login with the configured `jenkins_admin_user`/`jenkins_admin_password`. Confirm the `whanos-orchestrator` pipeline job exists and runs successfully.
2. **Registry**: `docker login registry.whanos.example.com` using the `registry_users` credentials. Verify TLS certificate validity.
3. **Kubernetes**:
   ```bash
   ssh deploy@master
   kubectl get nodes
   kubectl get pods -A
   ```
   Ensure all nodes are `Ready` and Calico pods are running in `kube-system`.
4. **Image pull secret**: create `whanos-registry` pull secret in each application namespace:
   ```bash
   kubectl create secret docker-registry whanos-registry \
     --docker-server=registry.whanos.example.com \
     --docker-username=ci \
     --docker-password='<password>' \
     --namespace=whanos-sample
   ```

## Dry-run redeploy procedure

Periodically verify that the documentation and playbooks can recreate the environment from scratch:

1. **Prepare clean VMs:** Provision fresh instances for Jenkins, registry, and Kubernetes nodes. Ensure DNS entries resolve to the new hosts.
2. **Clone repository:** Pull the infrastructure repo and customise `ansible/inventory/hosts.yml` plus sensitive defaults (use Ansible Vault for secrets).
3. **Execute provisioning:** Run `ansible-playbook ansible/site.yml`. Capture console output and record any manual interventions.
4. **Bootstrap CICD namespace:** Apply `kubernetes/base/jenkins-rbac.yaml` from the control plane.
5. **Publish base images:** Run `whanos-build` for each `images/*/Dockerfile.standalone` and push to the registry (or restore from backup).
6. **Run CI pipeline:** Trigger `whanos-orchestrator` against one example repository, confirming image build, scan, and push succeed.
7. **Deploy sample app:** Invoke `whanos-deploy` with the sample `whanos.yml`, verify service availability, and monitor events with `whanos-events`.
8. **Document gaps:** Update documentation or automation for any manual steps encountered; rerun the playbook to confirm idempotency.

## Cleanup & redeploy

- To reset a worker node: `kubeadm reset -f`, rerun the playbook targeting that host (`ansible-playbook site.yml --limit k8s_workers`).
- To rotate registry credentials, update `registry_users` in `roles/registry/defaults/main.yml`, rerun the registry play, then update Jenkins credentials (`jenkins_registry_username/password`) before re-running the Jenkins role.
- If Jenkins upgrades require plugin pinning, adjust `jenkins_version` and `jenkins_plugins` in the role defaults and rerun the play.
- To halt services without full teardown, use `./scripts/stop-whanos.sh` (add `--reset-k8s` for destructive cluster resets).
