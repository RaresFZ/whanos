# Whanos Docker Registry

This guide describes how to deploy and manage the private Docker registry that stores Whanos build artefacts.

## Topology

- **Host:** Any Linux VM with Docker/Podman installed (2 vCPU, 4 GB RAM, 20 GB disk recommended).
- **Service:** Official `registry:2` image bound to port 5000 (internal).
- **Proxy:** TLS-terminating reverse proxy (Traefik, nginx, or Caddy) exposing the registry on `https://registry.example.com`.
- **Storage:** Persistent volume mounted at `/var/lib/registry`. Back up this directory regularly.

## Deployment (Docker Compose example)

```yaml
version: "3.8"
services:
  registry:
    image: registry:2
    container_name: whanos-registry
    restart: unless-stopped
    environment:
      REGISTRY_HTTP_ADDR: 0.0.0.0:5000
      REGISTRY_STORAGE_DELETE_ENABLED: "true"
    volumes:
      - /srv/registry/data:/var/lib/registry
      - /srv/registry/auth:/auth
    networks:
      - registry

  proxy:
    image: traefik:v3.0
    container_name: whanos-registry-proxy
    restart: unless-stopped
    command:
      - "--providers.file.filename=/etc/traefik/dynamic.yml"
      - "--entrypoints.websecure.address=:443"
      - "--certificatesresolvers.le.acme.tlschallenge=true"
      - "--certificatesresolvers.le.acme.email=ops@example.com"
      - "--certificatesresolvers.le.acme.storage=/letsencrypt/acme.json"
    ports:
      - "443:443"
    volumes:
      - /srv/registry/traefik/dynamic.yml:/etc/traefik/dynamic.yml:ro
      - /srv/registry/letsencrypt:/letsencrypt
    networks:
      - registry

networks:
  registry:
    external: false
```

`dynamic.yml` (Traefik):

```yaml
http:
  routers:
    registry:
      entryPoints:
        - websecure
      rule: Host(`registry.example.com`)
      service: registry
      tls:
        certResolver: le
      middlewares:
        - registry-auth
  middlewares:
    registry-auth:
      basicAuth:
        usersFile: /auth/htpasswd
  services:
    registry:
      loadBalancer:
        servers:
          - url: http://whanos-registry:5000
```

Create the htpasswd file using `htpasswd -B -c /srv/registry/auth/htpasswd jenkins`.

## Credentials

- **Jenkins:** Store username/password in the `whanos-registry-creds` credential (Username with password type). Save the hostname (`registry.example.com`) as secret text (`whanos-registry-host`).
- **Kubernetes:** Create an image pull secret in the deployment namespace: `kubectl create secret docker-registry whanos-registry --docker-server=registry.example.com --docker-username=ci --docker-password='***'`.
- **Developers:** Provide read-only access tokens for debugging or manual pulls.

Rotate passwords quarterly. After rotation, update Jenkins credentials and the Kubernetes pull secret.

## Maintenance

- Enable periodic garbage collection: `docker exec whanos-registry bin/registry garbage-collect /etc/docker/registry/config.yml`.
- Monitor disk usage (`du -sh /srv/registry/data`) and Traefik access logs.
- Back up `/srv/registry/data` and `/srv/registry/letsencrypt` nightly.
- Document incident response: failed TLS renewal, credential leaks, space exhaustion.

## Integration checklist

1. Build and push the base images (`whanos-<lang>`) to the registry.
2. Configure Jenkins environment overrides (`WHANOS_BASE_IMAGE_*`) if base images live in the private registry.
3. Verify orchestrator login by running a dry run build with `--no-push`.
4. Register the registry host in Kubernetes nodes (`/etc/docker/daemon.json` → `{"insecure-registries": ["registry.example.com"]}`) if TLS offload is not used.
