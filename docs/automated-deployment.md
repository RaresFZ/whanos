# Whanos Automated Deployment

This document describes the automated configuration performed by the Whanos infrastructure deployment.

## Automated Components

### 1. Kubernetes Registry Integration

**Location:** `ansible/roles/kubernetes/tasks/control_plane.yml`

**What's automated:**
- **Containerd configuration**: Automatically configures `/etc/containerd/config.toml` to use the certs.d directory structure
- **Registry certificate trust**: Creates `/etc/containerd/certs.d/registry.whanos.example.com/hosts.toml` with TLS verification disabled for the local registry
- **ImagePullSecrets creation**: Automatically creates `registry-credentials` secret in:
  - `default` namespace
  - `whanos-cicd` namespace
- **Single-node scheduling**: Removes control-plane taint to allow pods to schedule on the master node

**Why this matters:**
- Eliminates manual intervention needed for pod image pulling
- Ensures containers can authenticate to the private registry
- Allows immediate deployment without manual kubectl commands

### 2. Jenkins Job Structure

**Location:** `ansible/roles/jenkins/tasks/main.yml`

**What's automated:**
- **Folder creation**:
  - `Whanos base images` folder - Contains all base image build jobs
  - `Projects` folder - Will contain all linked project CI/CD jobs
  
- **Base image build jobs**: Individual freestyle jobs for each language:
  - `Whanos base images/whanos-c`
  - `Whanos base images/whanos-java`
  - `Whanos base images/whanos-javascript`
  - `Whanos base images/whanos-python`
  - `Whanos base images/whanos-befunge`
  
- **Build all base images job**: Triggers all base image builds in parallel
  
- **link-project job**: Parameterized job that creates new CI/CD jobs for repositories
  - Parameters:
    - `REPOSITORY_URL`: Git clone URL
    - `REPOSITORY_NAME`: Friendly name for the job
    - `BRANCH`: Git branch to monitor (default: main)
    - `CREDENTIALS_ID`: Optional credentials for private repos
  - Uses Job DSL to dynamically create pipeline jobs in the Projects folder
  - Created jobs poll SCM every minute for changes

### 3. Jenkins Security

**Location:** `ansible/roles/jenkins/templates/jenkins.yaml.j2`

**What's configured:**
- **Sign-up disabled**: `allowsSignup: false` prevents unauthorized account creation
- **Admin user**: User "admin" with full administrative rights
- **Default credentials**: admin/changeme (should be changed in production)
- **Anonymous access**: Limited to read-only for the UI

### 4. Registry Credentials

**Location:** `ansible/roles/jenkins/templates/jenkins.yaml.j2`

**What's automated:**
- Jenkins credential `whanos-registry-creds` automatically created
- Used by pipelines to push images to the registry
- Matches the registry username/password configuration

## Usage

### Deploying a New Application

1. **Access Jenkins**: http://localhost:8080 (login: admin/changeme)

2. **Link your repository**:
   - Go to "link-project" job
   - Click "Build with Parameters"
   - Fill in:
     - `REPOSITORY_URL`: Your Git repository URL
     - `REPOSITORY_NAME`: Name for the job (e.g., "my-python-app")
     - `BRANCH`: main (or your default branch)
     - `CREDENTIALS_ID`: Leave empty for public repos

3. **Monitor the build**:
   - A new job appears in the `Projects` folder
   - It polls your repository every minute
   - On changes, it automatically builds and pushes to the registry

### Rebuilding Base Images

To rebuild all base images:
```bash
# In Jenkins, run the "Build all base images" job in the "Whanos base images" folder
```

Or rebuild a single language:
```bash
# Run the specific job, e.g., "Whanos base images/whanos-python"
```

## Architecture

```
Jenkins (localhost:8080)
├── link-project (job creator)
├── whanos-orchestrator (main pipeline)
├── Whanos base images/ (folder)
│   ├── whanos-c
│   ├── whanos-java
│   ├── whanos-javascript
│   ├── whanos-python
│   ├── whanos-befunge
│   └── Build all base images
└── Projects/ (folder)
    └── (dynamically created project jobs)

Registry (registry.whanos.example.com)
├── Authentication: ci/changeme
└── TLS: Self-signed (trusted by containerd)

Kubernetes (single-node)
├── Namespaces:
│   ├── default (with registry-credentials secret)
│   └── whanos-cicd (with registry-credentials secret)
└── Containerd: Configured to trust registry
```

## Configuration Variables

Key variables in `ansible/group_vars/all.yml`:
- `registry_hostname`: registry.whanos.example.com
- `registry_username`: ci
- `registry_password`: changeme
- `whanos_git_repo`: Your Whanos infrastructure repository
- `whanos_git_branch`: main

## Security Notes

⚠️ **For Production Use:**
1. Change default passwords (admin/changeme, ci/changeme)
2. Use proper TLS certificates instead of self-signed
3. Configure proper authentication mechanisms
4. Restrict network access appropriately
5. Enable RBAC in Kubernetes with proper service accounts

## Troubleshooting

### Pods can't pull images
The automation handles this, but if you still see issues:
```bash
# Check containerd configuration
sudo cat /etc/containerd/config.toml | grep config_path
# Should show: config_path = '/etc/containerd/certs.d'

# Check registry trust configuration  
sudo cat /etc/containerd/certs.d/registry.whanos.example.com/hosts.toml

# Check secrets exist
kubectl get secrets registry-credentials
kubectl get secrets -n whanos-cicd registry-credentials
```

### Jenkins jobs not appearing
```bash
# Check Jenkins logs
journalctl -u jenkins -n 100

# Verify folders were created
curl -u admin:changeme http://localhost:8080/api/json?tree=jobs[name]
```

### Base images not building
```bash
# Manually build
docker build -t whanos-python:latest -f images/python/Dockerfile.base images/python/

# Check Jenkins job logs in the "Whanos base images" folder
```
