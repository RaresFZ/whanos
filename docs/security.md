# Whanos Security Considerations

## Secrets management

- **Registry credentials:** Stored in Jenkins credentials store (`whanos-registry-creds`, `whanos-registry-host`). Rotate quarterly and update Ansible defaults and Kubernetes pull secrets in lockstep. Never commit plaintext secrets—use environment variables or encrypted secret managers for production.
- **Kubernetes kubeconfigs:** Jenkins should consume a restricted kubeconfig referencing the `whanos-deployer` service account. Store it on disk with `0600` permissions and rotate the token periodically (`kubectl create token`).
- **Ansible vault:** Use `ansible-vault` to encrypt sensitive group vars (e.g., actual registry passwords, Jenkins admin password) before running `ansible-playbook`. The repository default values are placeholders only.
- **Ingress TLS:** Terminate TLS for application ingress with valid certificates (Let's Encrypt via cert-manager or external proxy). Keep private keys in Kubernetes secrets; leverage external secret stores where possible.

## Access controls

- **Least privilege:** Jenkins deployer ServiceAccount is bound to a namespaced `Role` per application with only the verbs necessary to manage Deployments, Services, and Ingresses. The cluster-wide `whanos-deployer` `ClusterRole` only reads namespace metadata.
- **Registry access:** Use HTTP basic auth with bcrypt hashes and limit user accounts (CI vs. read-only). Consider enabling IP restrictions or mTLS if available.
- **Jenkins RBAC:** The JCasC configuration grants `admin` full control and anonymous read-only access. For production, integrate LDAP/OIDC and remove anonymous access if not required.
- **Node hardening:** Disable SSH password authentication, keep packages patched, and restrict sudo access to the deployment user.

## Image scanning

- Run `bin/whanos-scan registry.whanos.example.com/whanos/apps/foo:tag` post-build to check for CRITICAL/HIGH vulnerabilities using Trivy. Automate this as an optional Jenkins stage before publishing `latest`.
- Maintain `.trivyignore` files per repository to suppress false positives, documenting justification for each suppression.
- Periodically rescan base images (`whanos-*`) after upstream OS patches; rebuild and bump versions accordingly.

## Logging & monitoring

- Configure log shipping for Jenkins (`/var/log/jenkins/jenkins.log`) and Docker to a central collector (e.g., Loki, ELK) for auditability.
- Enable Kubernetes audit logging (via API server flags) and store logs in long-term storage.
- Track registry access logs (Caddy) to detect suspicious activity. Consider fail2ban or rate limiting.

## Backups & recovery

- Registry: snapshot `/srv/registry/data` and `/srv/registry/letsencrypt` daily.
- Jenkins: back up `/var/lib/jenkins` (jobs, credentials). Encrypt the backup artefacts.
- Kubernetes: back up etcd regularly (if self-managed) or rely on managed service snapshots.

## Future hardening ideas

- Integrate admission controllers (OPA/Gatekeeper) to enforce image provenance.
- Require signed images (Cosign + Rekor) and verify signatures during deployment.
- Add vulnerability scanning to the pipeline via Jenkins plugins or GitHub Actions.
