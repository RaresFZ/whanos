# Whanos Quick Start Guide

## Initial Deployment

1. **Configure your inventory:**
   ```yaml
   # ansible/inventory/hosts.yml
   all:
     hosts:
       whanos-server:
         ansible_host: your-server-ip
         ansible_user: deploy
   ```

2. **Set variables:**
   ```yaml
   # ansible/group_vars/all.yml
   whanos_domain: whanos.example.com
   registry_hostname: registry.whanos.example.com
   registry_username: ci
   registry_password: changeme  # Change this!
   ```

3. **Deploy everything:**
   ```bash
   cd ansible
   ansible-playbook -i inventory/hosts.yml site.yml
   ```

4. **Access your infrastructure:**
   - Jenkins: http://localhost:8080 (admin/changeme)
   - Registry: https://registry.whanos.example.com (ci/changeme)
   - Kubernetes: `kubectl get nodes`

## Using the link-project Job

### Linking a Public Repository

1. Open Jenkins: http://localhost:8080
2. Login with admin/changeme
3. Click on "link-project" job
4. Click "Build with Parameters"
5. Fill in:
   - **REPOSITORY_URL**: `https://github.com/yourusername/your-app.git`
   - **REPOSITORY_NAME**: `my-app`
   - **BRANCH**: `main`
   - **CREDENTIALS_ID**: (leave empty for public repos)
6. Click "Build"

### Linking a Private Repository

First, add credentials to Jenkins:

1. Go to "Manage Jenkins" → "Manage Credentials"
2. Click "(global)" domain
3. Click "Add Credentials"
4. Select "Username with password"
5. Fill in:
   - Username: Your Git username
   - Password: Your personal access token
   - ID: `github-my-account` (remember this!)
   - Description: "My GitHub account"
6. Click "Create"

Then link the project:

1. Click on "link-project" job
2. Click "Build with Parameters"
3. Fill in:
   - **REPOSITORY_URL**: `https://github.com/yourusername/private-app.git`
   - **REPOSITORY_NAME**: `my-private-app`
   - **BRANCH**: `main`
   - **CREDENTIALS_ID**: `github-my-account` (the ID you created)
4. Click "Build"

## What Happens Next

1. Jenkins creates a new job in the "Projects" folder
2. The job clones your repository
3. Every minute, it polls for changes
4. When changes are detected:
   - Detects the language (C/Java/JavaScript/Python/Befunge)
   - Builds a Docker image
   - Pushes to registry.whanos.example.com
   - If whanos.yml exists, deploys to Kubernetes

## Repository Requirements

Your repository must have:

1. An `app/` directory with your source code
2. One of these detection files:
   - **C**: Makefile at root
   - **Java**: pom.xml at root
   - **JavaScript**: package.json at root
   - **Python**: requirements.txt at root
   - **Befunge**: main.bf in app/

3. (Optional) A whanos.yml file for deployment:

```yaml
deployment:
  replicas: 2
  resources:
    limits:
      memory: "512Mi"
      cpu: "500m"
    requests:
      memory: "256Mi"
      cpu: "250m"
  ports:
    - 8080
```

## Checking Your Build

1. Go to "Projects" folder in Jenkins
2. Click on your project name
3. Click on the latest build number
4. Click "Console Output" to see logs

## Accessing Your Deployed Applications

Once your application is deployed with a valid `whanos.yml`, here's how to access it:

### Quick Method: Find All Deployed Apps

```bash
# List all Whanos deployments
kubectl get deployments -A | grep whanos

# List all Whanos services and ingresses
kubectl get svc,ingress -A | grep whanos
```

### Step-by-Step: Finding Your App's URL

#### 1. Find Your App's Namespace
```bash
kubectl get ns | grep whanos
```
Your app will be in a namespace like `whanos-<app-name>` or `whanos-cicd`.

#### 2. Check the Ingress
```bash
kubectl get ingress -n <namespace>
```

Example output:
```
NAME            CLASS     HOSTS   ADDRESS                            PORTS   AGE
python-whanos   traefik   *       172.20.0.2,172.20.0.3,172.20.0.4   80      12m
```

#### 3. Get the Ingress Path
```bash
kubectl describe ingress <app-name> -n <namespace>
```

Look for the `Rules` section to find the path (e.g., `/python-whanos`).

#### 4. Find the k3d Port Mapping
```bash
docker ps --filter "name=k3d-whanos-serverlb" --format "{{.Ports}}"
```

Look for port 80 mapping (e.g., `0.0.0.0:8081->80/tcp` means port 8081).

#### 5. Access Your App
Your app will be available at:
```
http://localhost:<k3d-port>/<app-path>
```

**Example**: `http://localhost:8081/python-whanos`

### Quick Access Script

Save this as `whanos-find-app.sh`:
```bash
#!/bin/bash
APP=${1:-}

if [[ -z "$APP" ]]; then
  echo "Usage: $0 <app-name>"
  echo ""
  echo "Available apps:"
  kubectl get ingress -A -o custom-columns=NAMESPACE:.metadata.namespace,NAME:.metadata.name
  exit 1
fi

# Find namespace
NAMESPACE=$(kubectl get ingress -A -o json | jq -r ".items[] | select(.metadata.name==\"$APP\") | .metadata.namespace" | head -1)

if [[ -z "$NAMESPACE" ]]; then
  echo "App '$APP' not found"
  exit 1
fi

# Get ingress path
PATH_INFO=$(kubectl get ingress "$APP" -n "$NAMESPACE" -o json | jq -r '.spec.rules[0].http.paths[0].path // "/"')

# Get k3d port
K3D_PORT=$(docker ps --filter "name=k3d-whanos-serverlb" --format "{{.Ports}}" | grep -oP '0.0.0.0:\K\d+(?=->80/tcp)' | head -1)

echo ""
echo "✅ Application: $APP"
echo "📦 Namespace: $NAMESPACE"
echo "🔗 Path: $PATH_INFO"
echo "🌐 Access URL: http://localhost:${K3D_PORT}${PATH_INFO}"
echo ""
```

Make it executable and use it:
```bash
chmod +x whanos-find-app.sh
./whanos-find-app.sh python-whanos
```

### Alternative: NodePort Access

If you prefer NodePort instead of Ingress:

1. **Convert service to NodePort:**
   ```bash
   kubectl patch svc <app-name> -n <namespace> -p '{"spec":{"type":"NodePort"}}'
   ```

2. **Get the NodePort:**
   ```bash
   kubectl get svc <app-name> -n <namespace>
   ```
   
   Look for `PORT(S)` like `8080:30123/TCP` where `30123` is the NodePort.

3. **Access the app:**
   ```
   http://localhost:30123
   ```

### Checking Application Status

```bash
# Check if pods are running
kubectl get pods -n <namespace>

# View application logs
kubectl logs -n <namespace> deployment/<app-name>

# Check service details
kubectl describe svc <app-name> -n <namespace>

# Watch pod status in real-time
kubectl get pods -n <namespace> -w
```

## Checking Your Deployment

```bash
# List all deployments
kubectl get deployments

# Check pods
kubectl get pods

# View pod logs
kubectl logs <pod-name>

# Check service ports
kubectl get services
```

## Rebuilding Base Images

If you modify a Dockerfile.base:

**Rebuild one language:**
1. Go to "Whanos base images" folder
2. Click the language (e.g., "whanos-python")
3. Click "Build Now"

**Rebuild all languages:**
1. Go to "Whanos base images" folder
2. Click "Build all base images"
3. Click "Build Now"

## Troubleshooting

### kubectl can't connect to cluster (connection refused)

This happens when your network connection drops or your IP address changes. The kubeconfig still points to the old IP.

**Quick fix:**
```bash
./scripts/fix-kubeconfig.sh
```

**Manual fix:**
```bash
k3d kubeconfig merge whanos --kubeconfig-merge-default --kubeconfig-switch-context
```

### Job not polling my repository
- Check the job configuration: Projects → your-job → Configure
- Verify "Poll SCM" is enabled with schedule `* * * * *`
- Check Jenkins system log for errors

### Build failing with "language not detected"
- Verify you have the correct detection file:
  - C: Makefile at root
  - Java: pom.xml at root
  - JavaScript: package.json at root
  - Python: requirements.txt at root
  - Befunge: main.bf in app/ directory

### Pod can't pull image
- This should be automatic now, but verify:
```bash
# Check secrets exist
kubectl get secret registry-credentials

# Check containerd config
sudo cat /etc/containerd/config.toml | grep config_path
```

### Can't access deployed application
```bash
# Check service
kubectl get svc

# If using NodePort, access via:
# http://<node-ip>:<node-port>

# Check pod logs for errors
kubectl logs <pod-name>
```

## Example Repositories

Test examples are in `whanos_example_apps/`:
- `c-hello-world/`: Simple C program
- `java-hello-world/`: Maven-based Java app
- `js-hello-world/`: Node.js application
- `python-hello-world/`: Python module
- `befunge-hello-world/`: Befunge script

## Advanced: Custom Dockerfile

To use a custom Dockerfile with Whanos base image:

1. Create a Dockerfile at the root of your repo:
```dockerfile
FROM whanos-python:latest

# Your custom configuration
RUN pip install additional-package

# Whanos base image already:
# - Sets WORKDIR to /app
# - Copies requirements.txt and installs dependencies
# - Sets CMD to run the app
```

2. Push to your repository
3. Jenkins will detect the Dockerfile and use it instead of the standalone image

## Next Steps

- Change default passwords (admin, registry)
- Set up proper DNS for your domain
- Configure SSL certificates (Let's Encrypt)
- Set up monitoring
- Configure backups
- Add more projects!
