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
   - **Java**: pom.xml in app/
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

### Job not polling my repository
- Check the job configuration: Projects → your-job → Configure
- Verify "Poll SCM" is enabled with schedule `* * * * *`
- Check Jenkins system log for errors

### Build failing with "language not detected"
- Verify you have the correct detection file:
  - C: Makefile at root
  - Java: pom.xml in app/ directory
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
