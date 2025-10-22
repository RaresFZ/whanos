# Whanos Infrastructure

This documentation folder will collect the operational notes, architecture decisions, and usage guides required to operate the Whanos infrastructure.

## Architecture overview

- **Source control:** Developers push Whanos-compatible repositories (one app per repo) to Git hosting.
- **CI/CD (Jenkins):** A parameterised pipeline (`Jenkinsfile`) checks out both infrastructure and application repositories, runs the Whanos orchestrator, and publishes images into the private registry.
- **Registry:** The hardened Docker registry stores both base images (`whanos-*`) and application artefacts under `whanos/apps/<repo>:<tag>`.
- **Deployment tooling:** The Jenkins pipeline or operators call `kubernetes/render_deployment.py` (via `bin/whanos-deploy`) to translate `whanos.yml` into Kubernetes manifests with RBAC scoped to the app namespace.
- **Kubernetes cluster:** A kubeadm-based cluster (1 control plane + ≥2 workers) runs the applications. Namespaces (`whanos-<app>`) isolate workloads, with shared CICD namespace `whanos-cicd` hosting the deployer ServiceAccount.

High-level flow: `git push` → Jenkins build → orchestrator detects language & builds image → image pushed to registry → manifests rendered → `kubectl apply` deploys or updates the app in Kubernetes.

## Base images overview

| Language   | Base tag        | Build expectation                                                                | Default runtime command                     |
|------------|-----------------|----------------------------------------------------------------------------------|---------------------------------------------|
| C          | `whanos-c`      | Run `make` to compile into `compiled-app` at the repo root.                      | `./compiled-app`                            |
| Java       | `whanos-java`   | Execute `mvn -f app/pom.xml -DskipTests package` to produce `app/target/app.jar`.| `java -jar app/target/app.jar`              |
| JavaScript | `whanos-javascript` | Install dependencies with `npm ci --omit=dev` or `npm install --production`. | `node .`                                    |
| Python     | `whanos-python` | Install dependencies from `requirements.txt`.                                    | `python -m app`                             |
| Befunge    | `whanos-befunge`| Ensure `app/main.bf` exists.                                                     | `befunge93 app/main.bf`                     |

Each `Dockerfile.standalone` extends its paired base image and demonstrates how the Whanos builder can assemble a runnable image directly from a compliant repository. These files double as integration tests for the base images using the sample applications under `whanos_example_apps/`.

## Automation orchestrator

`orchestrator/main.py` is the single entry point used by the CI/CD system to containerize an application repository.

- **Detection rules:** `Makefile` ⇒ C, `app/pom.xml` ⇒ Java, `package.json` ⇒ JavaScript, `requirements.txt` ⇒ Python, `app/main.bf` ⇒ Befunge. Detection failures or collisions abort the build with a descriptive error.
- **Customizations:** Repositories can provide `whanos/Dockerfile.override` (full control) or `whanos/Dockerfile.append` (appended instructions) to extend the generated Dockerfile while still inheriting from the Whanos base image.
- **Tests:** Before the container build, the orchestrator executes language-appropriate test commands inside the base image (`mvn test`, `npm test` when declared, `pytest` when a `tests/` tree exists). `--skip-tests` disables this phase when needed.
- **Registry integration:** The target image reference is injected via `--image`. Registry host and credentials travel through environment variables (`WHANOS_REGISTRY_USERNAME` / `WHANOS_REGISTRY_PASSWORD`) and the optional `--registry` flag triggers a `docker login`.
- **Build arguments:** CI can forward additional `--build-arg KEY=VALUE` flags. All arguments are generated within the pipeline to avoid shell quoting issues.

Example usage from Jenkins:

```bash
python3 orchestrator/main.py \
  --repo "${WORKSPACE}/app" \
  --image "${REGISTRY_HOST}/whanos/apps/example:${GIT_COMMIT}" \
  --registry "${REGISTRY_HOST}"
```

## CI/CD pipeline (Jenkins)

The declarative `Jenkinsfile` provisions a parameterised build that:

1. Checks out both the infrastructure repository (this project) and the target application repository (`APP_REPOSITORY` + `APP_BRANCH` parameters).
2. Computes deterministic image tags based on the application name, branch, and commit.
3. Invokes the orchestrator with the proper registry credentials (stored as Jenkins credentials `whanos-registry-host` + `whanos-registry-creds`).
4. Optionally forwards extra build arguments and allows the test phase to be skipped for hotfix scenarios.
5. Retags the produced image with a stable `<branch>:latest` alias after a successful push.

Pipeline parameters to configure per job:

- `APP_REPOSITORY`: Git clone URL of the developer application.
- `APP_BRANCH`: Branch/ref to build (defaults to `main`).
- `SKIP_TESTS`: Toggle to bypass the orchestrator pre-build tests.
- `ADDITIONAL_BUILD_ARGS`: Optional newline separated list of `KEY=VALUE` pairs forwarded to `docker build`.

Secrets handled via Jenkins credentials:

- `whanos-registry-host`: secret text containing the hostname of the Docker registry.
- `whanos-registry-creds`: username/password pair used by the orchestrator for `docker login`.

Pipeline options enforce log retention (`25` builds / `14` days) and ANSI-coloured, timestamped output for easier troubleshooting.

## Registry setup

A private Docker registry is required so that Jenkins can publish build artefacts and the Kubernetes cluster can pull them. The recommended approach is:

1. Deploy the official `registry:2` container (e.g., with Docker Compose or a dedicated VM) and persist data to a mounted volume.
2. Front the registry with a TLS-terminating reverse proxy (Caddy, Traefik, or nginx) that issues certificates (Let’s Encrypt) and enforces HTTP basic authentication.
3. Create registry credentials dedicated to Jenkins and any automated deployer. Store those secrets in Jenkins (`whanos-registry-creds`) and in the Kubernetes pull secret.
4. Configure the registry hostname inside Jenkins (`whanos-registry-host`) and in the orchestrator environment (`WHANOS_BASE_IMAGE_*`) when base images are mirrored.
5. Document the credential rotation policy and backup/restore process for the registry volume.

## Infrastructure provisioning (Ansible)

The `ansible/` tree contains the automation that bootstraps the Whanos infrastructure:

- `site.yml` orchestrates role execution across inventory groups (`jenkins`, `registry`, `k8s_control_plane`, `k8s_workers`).
- `roles/jenkins` installs Docker, configures Jenkins via Configuration-as-Code, seeds the Whanos pipeline job, and ensures required plugins are installed.
- `roles/registry` deploys the Docker registry plus a Caddy reverse proxy with TLS and HTTP basic authentication. Credentials are stored in `registry_users`.
- `roles/kubernetes` provisions a two-tier kubeadm cluster (containerd runtime), initialises the control plane, distributes join commands, installs Calico, and joins worker nodes.
- `inventory/hosts.yml` ships with placeholder hosts—replace with your infrastructure before running `ansible-playbook`.

Additional details and prerequisites are documented in `docs/provisioning.md`.

## Operational CLI helpers

Helper utilities under `bin/` simplify day-to-day operations:

- `whanos-build`: wraps `orchestrator/main.py` for ad-hoc local builds (`--repo`, `--image`, `--skip-tests`, `--no-push`).
- `whanos-deploy`: renders manifests and optionally applies them via `kubectl` (`--dry-run`, `--output-dir`, `--expose-mode`, `--domain`, `--nodeport-base`).
- `whanos-clean-releases`: prunes older ReplicaSets for an application while keeping the most recent revisions (defaults to 2).
- `whanos-events`: tails cluster events with an optional namespace/app filter, supporting continuous refresh (`--follow`).

Add the repository `bin/` directory to your `$PATH` to access these commands easily.

## Provisioning wrappers

- `scripts/start-whanos.sh`: orchestrates `ansible-playbook`, applies Jenkins RBAC, and optionally bootstraps/pushes sample images. Pass `--bootstrap-base-images` and `--registry <host>` to build demos automatically.
- `scripts/stop-whanos.sh`: stops Jenkins, tears down the registry compose stack, and (optionally) resets Kubernetes nodes via ad-hoc Ansible commands (`--reset-k8s`).

## Kubernetes deployment tooling

The `kubernetes/` directory provides cluster artefacts:

- `render_deployment.py` parses an application's `whanos.yml` and renders Namespaces, Deployments, Services, Ingresses, and per-app RBAC bindings that grant Jenkins' `whanos-deployer` service account the necessary permissions. Supports ingress/nodeport exposure modes and namespace isolation.
- `base/jenkins-rbac.yaml` seeds the cluster with a dedicated CICD namespace and a service account bound to a ClusterRole that can read namespaces and manage supporting config objects.

Operators can integrate the renderer into the pipeline's post-build steps to continuously deploy newly built images.

## Provisioning quick start

1. Edit `ansible/inventory/hosts.yml` with your hostnames/IPs.
2. Populate `group_vars/all.yml` with domain names and default credentials (rotate `changeme` values).
3. Install required Ansible collections (`community.general`, `community.docker`).
4. Run `ansible-playbook ansible/site.yml`. Re-run safely for upgrades or credential rotations.
5. Apply `kubernetes/base/jenkins-rbac.yaml` once the cluster is ready.

See `docs/provisioning.md` for a full breakdown.

## Pipeline to deployment walkthrough

Using `whanos_example_apps/js-hello-world` as an example:

1. **Developer push:** the repository contains `package.json`, `app/app.js`, and optional `whanos.yml`.
2. **Pipeline trigger:** Jenkins job `whanos-orchestrator` runs with parameters:
   ```text
   APP_REPOSITORY = git@github.com:org/js-hello-world.git
   APP_BRANCH     = main
   ```
3. **Orchestrator phase:** detects JavaScript (presence of `package.json`), runs `npm test` if defined, builds the image extending `whanos-javascript`, and pushes it as `registry.whanos.example.com/whanos/apps/js-hello-world:<commit>`.
4. **Deploy phase (manual or automated):**
   ```bash
   whanos-deploy \
     --config whanos.yml \
     --image registry.whanos.example.com/whanos/apps/js-hello-world:abcd123 \
     --app js-hello-world \
     --domain apps.whanos.example.com
   ```
   This command renders manifests, applies them to namespace `whanos-js-hello-world`, and exposes the service at `https://js-hello-world.apps.whanos.example.com`.
5. **Verification:** `kubectl rollout status deployment/js-hello-world -n whanos-js-hello-world` confirms the deployment is live. Use `whanos-events --app js-hello-world --follow` to monitor events during rollout.

## Troubleshooting & monitoring basics

- **Jenkins logs:** Build retention is capped at 25 runs / 14 days. Download full console logs when investigating long-standing issues. Use the Jenkins CLI helper (`/usr/local/bin/jenkins-cli.sh`) to inspect job status.
- **Registry health:** `docker login` regularly to confirm credentials, and monitor Caddy logs for TLS renewal. Run `docker compose logs -f proxy registry` on the registry host when debugging push failures.
- **Kubernetes events:** `bin/whanos-events` surfaces the latest cluster events. Combine with `kubectl describe pod <name>` for detailed failure messages.
- **ReplicaSet cleanup:** `bin/whanos-clean-releases --app foo --keep 2` removes old revisions after successful rollouts to keep the namespace tidy.
- **Configuration drift:** Re-apply Ansible playbooks to restore configuration; the roles are idempotent and safe to re-run.

## Validation & test plan

1. **Base image smoke tests:** Build each language sample locally:
   ```bash
   whanos-build --repo whanos_example_apps/python-hello-world \
                --image registry.local/whanos/apps/python-hello-world:test \
                --no-push
   ```
   Repeat for C, Java, JavaScript, TypeScript (standalone via JS image), and Befunge samples.
2. **Registry push/pull:** Execute `whanos-build` without `--no-push` to push into the registry, then `docker pull` from another host to confirm access.
3. **Deployment:** For every sample:
   ```bash
   whanos-deploy --config whanos_example_apps/<lang>-hello-world/whanos.yml \
                 --image registry.local/whanos/apps/<lang>-hello-world:test \
                 --app <lang>-hello-world --dry-run
   ```
   Inspect manifests, then deploy without `--dry-run` and verify service accessibility (e.g., `curl`, browser).
4. **Rollback check:** Deploy an updated image, then run `kubectl rollout undo deployment/<app> -n whanos-<app>` to ensure prior ReplicaSets remain viable. Clean old ones with `whanos-clean-releases` afterwards.
5. **Failure modes:** Deliberately break `whanos.yml` (missing ports) or tests to confirm Jenkins stops and reports meaningful error messages from the orchestrator.

## Security checklist

- Review `docs/security.md` for detailed guidance on secrets rotation, RBAC scopes, and platform hardening.
- Keep real credentials outside of Git (Ansible Vault, Jenkins credentials). All `changeme` defaults must be replaced before production use.
- Run `whanos-scan` (Trivy) after each build or on a schedule to catch CRITICAL/HIGH vulnerabilities before promoting images.
- Restrict Jenkins and registry exposure to trusted networks; enforce TLS end-to-end and monitor access logs.
- Back up Jenkins home, registry data, and Kubernetes control-plane state regularly to validate disaster recovery.

## Future enhancements

- Capture an ASCII or rendered architecture diagram to complement the textual overview.
- Automate ingress certificate provisioning for application hostnames.
- Extend the orchestrator to support additional languages (Go, Rust, etc.).
