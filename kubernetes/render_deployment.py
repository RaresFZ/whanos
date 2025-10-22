#!/usr/bin/env python3
"""
Render Kubernetes manifests from a Whanos deployment descriptor.

Usage example:

    python render_deployment.py \
        --config whanos.yml \
        --image registry.example.com/whanos/apps/sample:abcd123 \
        --app sample \
        --namespace whanos-sample \
        --deployer-service-account jenkins/whanos-deployer \
        --domain apps.whanos.example.com \
        --output-dir manifests
"""

from __future__ import annotations

import argparse
import os
from pathlib import Path
from typing import Dict, List, Optional, Tuple

import yaml


class RenderError(RuntimeError):
    """Raised when the deployment rendering fails."""


def load_config(path: Path) -> Dict:
    if not path.exists():
        raise RenderError(f"Configuration file not found: {path}")
    with path.open("r", encoding="utf-8") as fh:
        data = yaml.safe_load(fh) or {}
    if not isinstance(data, dict):
        raise RenderError("whanos.yml must contain a mapping at the root.")
    return data


def extract_deployment(config: Dict) -> Dict:
    deployment = config.get("deployment")
    if deployment is None:
        raise RenderError("'deployment' section missing in whanos.yml. Nothing to render.")
    if not isinstance(deployment, dict):
        raise RenderError("'deployment' must be a mapping in whanos.yml.")
    return deployment


def ensure_namespace_manifest(namespace: str, labels: Dict[str, str]) -> Dict:
    return {
        "apiVersion": "v1",
        "kind": "Namespace",
        "metadata": {
            "name": namespace,
            "labels": labels,
        },
    }


def build_deployment_manifest(
    *,
    app: str,
    namespace: str,
    image: str,
    replicas: int,
    resources: Optional[Dict],
    ports: List[int],
    env: Optional[List[Dict[str, str]]] = None,
) -> Dict:
    container_ports = [{"containerPort": port, "name": f"tcp-{port}"} for port in ports]
    manifest: Dict = {
        "apiVersion": "apps/v1",
        "kind": "Deployment",
        "metadata": {
            "name": app,
            "namespace": namespace,
            "labels": {
                "app.kubernetes.io/name": app,
                "app.kubernetes.io/managed-by": "whanos",
            },
        },
        "spec": {
            "replicas": replicas,
            "selector": {
                "matchLabels": {
                    "app.kubernetes.io/name": app,
                }
            },
            "template": {
                "metadata": {
                    "labels": {
                        "app.kubernetes.io/name": app,
                        "app.kubernetes.io/managed-by": "whanos",
                    }
                },
                "spec": {
                    "containers": [
                        {
                            "name": app,
                            "image": image,
                            "imagePullPolicy": "IfNotPresent",
                            "ports": container_ports if container_ports else None,
                            "resources": resources if resources else None,
                            "env": env if env else None,
                        }
                    ],
                },
            },
        },
    }

    # Clean up None entries to keep manifest concise
    container_spec = manifest["spec"]["template"]["spec"]["containers"][0]
    for key in ("ports", "resources", "env"):
        if container_spec.get(key) is None:
            container_spec.pop(key, None)

    return manifest


def build_service_manifest(
    *,
    app: str,
    namespace: str,
    ports: List[int],
    service_type: str,
    nodeport_base: int,
) -> Optional[Dict]:
    if not ports:
        return None

    service_ports = []
    for index, port in enumerate(ports):
        service_port: Dict[str, int] = {
            "name": f"tcp-{port}",
            "protocol": "TCP",
            "port": port,
            "targetPort": port,
        }
        if service_type == "NodePort":
            service_port["nodePort"] = nodeport_base + index
        service_ports.append(service_port)

    manifest = {
        "apiVersion": "v1",
        "kind": "Service",
        "metadata": {
            "name": app,
            "namespace": namespace,
            "labels": {
                "app.kubernetes.io/name": app,
                "app.kubernetes.io/managed-by": "whanos",
            },
        },
        "spec": {
            "selector": {
                "app.kubernetes.io/name": app,
            },
            "type": service_type,
            "ports": service_ports,
        },
    }
    return manifest


def build_ingress_manifest(
    *,
    app: str,
    namespace: str,
    domain: str,
    ports: List[int],
    tls_secret: Optional[str],
) -> Dict:
    if not ports:
        raise RenderError("Cannot create ingress without exposed ports.")

    primary_port = ports[0]
    rules = [
        {
            "host": f"{app}.{domain}",
            "http": {
                "paths": [
                    {
                        "path": "/",
                        "pathType": "Prefix",
                        "backend": {
                            "service": {
                                "name": app,
                                "port": {"number": primary_port},
                            }
                        },
                    }
                ]
            },
        }
    ]

    manifest: Dict = {
        "apiVersion": "networking.k8s.io/v1",
        "kind": "Ingress",
        "metadata": {
            "name": f"{app}-ingress",
            "namespace": namespace,
            "annotations": {
                "nginx.ingress.kubernetes.io/backend-protocol": "HTTP",
            },
        },
        "spec": {
            "rules": rules,
        },
    }

    if tls_secret:
        manifest["spec"]["tls"] = [
            {
                "hosts": [f"{app}.{domain}"],
                "secretName": tls_secret,
            }
        ]

    return manifest


def build_role_manifest(namespace: str, app: str) -> Dict:
    return {
        "apiVersion": "rbac.authorization.k8s.io/v1",
        "kind": "Role",
        "metadata": {
            "name": f"{app}-deployer",
            "namespace": namespace,
        },
        "rules": [
            {
                "apiGroups": [""],
                "resources": ["pods", "services", "configmaps", "secrets"],
                "verbs": ["get", "list", "watch", "create", "update", "patch", "delete"],
            },
            {
                "apiGroups": ["apps"],
                "resources": ["deployments", "replicasets"],
                "verbs": ["get", "list", "watch", "create", "update", "patch", "delete"],
            },
            {
                "apiGroups": ["networking.k8s.io"],
                "resources": ["ingresses"],
                "verbs": ["get", "list", "watch", "create", "update", "patch", "delete"],
            },
        ],
    }


def build_role_binding_manifest(
    namespace: str,
    app: str,
    deployer_service_account: Tuple[str, str],
) -> Dict:
    deployer_namespace, service_account = deployer_service_account
    return {
        "apiVersion": "rbac.authorization.k8s.io/v1",
        "kind": "RoleBinding",
        "metadata": {
            "name": f"{app}-deployer-binding",
            "namespace": namespace,
        },
        "subjects": [
            {
                "kind": "ServiceAccount",
                "name": service_account,
                "namespace": deployer_namespace,
            }
        ],
        "roleRef": {
            "apiGroup": "rbac.authorization.k8s.io",
            "kind": "Role",
            "name": f"{app}-deployer",
        },
    }


def parse_service_account(value: str) -> Tuple[str, str]:
    if "/" not in value:
        raise RenderError("--deployer-service-account must be in the form <namespace>/<name>")
    namespace, name = value.split("/", 1)
    if not namespace or not name:
        raise RenderError("--deployer-service-account is invalid: %s" % value)
    return namespace, name


def dump_manifest(manifest: Dict) -> str:
    return yaml.safe_dump(manifest, sort_keys=False)


def write_manifest(manifest: Dict, output_dir: Optional[Path], filename: str) -> None:
    content = dump_manifest(manifest)
    if output_dir:
        output_dir.mkdir(parents=True, exist_ok=True)
        (output_dir / filename).write_text(content, encoding="utf-8")
    else:
        print("---")
        print(content)


def render(
    *,
    config_path: Path,
    image: str,
    namespace: str,
    app: str,
    deployer_service_account: Tuple[str, str],
    expose_mode: str,
    service_type: str,
    nodeport_base: int,
    domain: Optional[str],
    tls_secret: Optional[str],
    output_dir: Optional[Path],
) -> None:
    config = load_config(config_path)
    deployment_cfg = extract_deployment(config)

    replicas = int(deployment_cfg.get("replicas", 1))
    resources = deployment_cfg.get("resources")
    raw_ports = deployment_cfg.get("ports") or []
    if not isinstance(raw_ports, list):
        raise RenderError("'deployment.ports' must be a list of integers.")
    try:
        ports = sorted({int(port) for port in raw_ports})
    except (TypeError, ValueError) as exc:
        raise RenderError("Ports must be numeric.") from exc

    manifests: List[Tuple[str, Dict]] = []

    namespace_labels = {
        "app.kubernetes.io/managed-by": "whanos",
        "whanos/app": app,
    }
    manifests.append(("namespace.yaml", ensure_namespace_manifest(namespace, namespace_labels)))

    manifests.append(
        (
            "deployment.yaml",
            build_deployment_manifest(
                app=app,
                namespace=namespace,
                image=image,
                replicas=replicas,
                resources=resources,
                ports=ports,
            ),
        )
    )

    if expose_mode == "nodeport" and service_type != "NodePort":
        service_type = "NodePort"

    service_manifest = build_service_manifest(
        app=app,
        namespace=namespace,
        ports=ports,
        service_type=service_type,
        nodeport_base=nodeport_base,
    )
    if service_manifest:
        manifests.append(("service.yaml", service_manifest))

    if expose_mode == "ingress":
        if not domain:
            raise RenderError("Ingress exposure selected but --domain not provided.")
        manifests.append(
            (
                "ingress.yaml",
                build_ingress_manifest(
                    app=app,
                    namespace=namespace,
                    domain=domain,
                    ports=ports,
                    tls_secret=tls_secret,
                ),
            )
        )

    manifests.append(("role.yaml", build_role_manifest(namespace, app)))
    manifests.append(
        (
            "rolebinding.yaml",
            build_role_binding_manifest(namespace, app, deployer_service_account),
        )
    )

    for filename, manifest in manifests:
        write_manifest(manifest, output_dir, filename)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Render Kubernetes manifests from a whanos.yml file.")
    parser.add_argument("--config", default="whanos.yml", help="Path to whanos.yml (default: ./whanos.yml).")
    parser.add_argument("--image", required=True, help="Container image to deploy.")
    parser.add_argument("--app", required=True, help="Application name (used for resource names).")
    parser.add_argument("--namespace", help="Namespace to deploy into (default: whanos-<app>).")
    parser.add_argument(
        "--deployer-service-account",
        default="jenkins/whanos-deployer",
        help="ServiceAccount (namespace/name) Jenkins uses for deployments.",
    )
    parser.add_argument(
        "--expose-mode",
        choices=["ingress", "clusterip", "nodeport"],
        default="ingress",
        help="How to expose ports (default: ingress).",
    )
    parser.add_argument(
        "--service-type",
        choices=["ClusterIP", "NodePort", "LoadBalancer"],
        default="ClusterIP",
        help="Service type to create (default: ClusterIP).",
    )
    parser.add_argument(
        "--nodeport-base",
        type=int,
        default=30000,
        help="Base NodePort value when expose-mode=nodeport (default: 30000).",
    )
    parser.add_argument(
        "--domain",
        help="Base domain for ingress hosts (required for expose-mode=ingress).",
    )
    parser.add_argument(
        "--tls-secret",
        help="Optional TLS secret name for the ingress.",
    )
    parser.add_argument(
        "--output-dir",
        help="Directory to write manifests into. Prints to stdout when omitted.",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()

    namespace = args.namespace or f"whanos-{args.app}"
    deployer_service_account = parse_service_account(args.deployer_service_account)

    try:
        render(
            config_path=Path(args.config).resolve(),
            image=args.image,
            namespace=namespace,
            app=args.app,
            deployer_service_account=deployer_service_account,
            expose_mode=args.expose_mode,
            service_type=args.service_type,
            nodeport_base=args.nodeport_base,
            domain=args.domain,
            tls_secret=args.tls_secret,
            output_dir=Path(args.output_dir).resolve() if args.output_dir else None,
        )
    except RenderError as exc:
        raise SystemExit(f"ERROR: {exc}") from exc

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
