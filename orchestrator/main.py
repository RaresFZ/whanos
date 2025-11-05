#!/usr/bin/env python3
"""Whanos build orchestrator.

This script detects the technology of a Whanos-compatible repository, executes the
expected validation steps, crafts a Dockerfile that extends the official Whanos base
image for the detected language, builds the resulting container image, and pushes it
to the configured registry.
"""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
import tempfile
from dataclasses import dataclass
import json
from pathlib import Path
from typing import Callable, Dict, List, Optional


class OrchestratorError(RuntimeError):
    """Raised when the orchestrator cannot complete its workflow."""


def run_command(
    command: List[str],
    *,
    cwd: Optional[Path] = None,
    check: bool = True,
    capture_output: bool = False,
) -> subprocess.CompletedProcess:
    """Run a shell command and wrap subprocess.run for better error messages."""
    try:
        result = subprocess.run(
            command,
            cwd=str(cwd) if cwd else None,
            check=check,
            text=True,
            capture_output=capture_output,
        )
    except subprocess.CalledProcessError as exc:
        raise OrchestratorError(
            f"Command failed with exit code {exc.returncode}: {' '.join(command)}\n"
            f"stdout:\n{exc.stdout}\n\nstderr:\n{exc.stderr}"
        ) from exc
    return result


def path_exists(path: Path) -> bool:
    """Helper that checks for the existence of a path, accounting for symlinks."""
    return path.exists() or path.is_symlink()


@dataclass(frozen=True)
class LanguageConfig:
    name: str
    detector: Callable[[Path], bool]
    base_image_env: str
    default_base_image: str
    test_command: Callable[[Path], Optional[List[str]]]
    dockerfile_instructions: Callable[[Path], List[str]]


def detect_c(repo_root: Path) -> bool:
    return path_exists(repo_root / "Makefile")


def detect_java(repo_root: Path) -> bool:
    return path_exists(repo_root / "pom.xml")


def detect_javascript(repo_root: Path) -> bool:
    return path_exists(repo_root / "package.json")


def detect_python(repo_root: Path) -> bool:
    return path_exists(repo_root / "requirements.txt")


def detect_befunge(repo_root: Path) -> bool:
    return path_exists(repo_root / "app" / "main.bf")


def test_command_none(_: Path) -> Optional[List[str]]:
    return None


def docker_steps_c(_: Path) -> List[str]:
    return [
        "COPY . .",
        "RUN make",
        'CMD ["./compiled-app"]',
    ]


def docker_steps_java(_: Path) -> List[str]:
    return [
        "COPY . .",
        "RUN mvn -DskipTests package",
        'CMD ["java", "-jar", "target/app.jar"]',
    ]


def docker_steps_javascript(_: Path) -> List[str]:
    return [
        "COPY package*.json ./",
        "RUN npm ci --omit=dev || npm install --production",
        "COPY . .",
        'CMD ["node", "."]',
    ]


def docker_steps_python(repo_root: Path) -> List[str]:
    instructions: List[str] = []
    requirements = repo_root / "requirements.txt"
    if path_exists(requirements):
        instructions.append("COPY requirements.txt ./")
        instructions.append("RUN pip install --no-cache-dir -r requirements.txt")
    else:
        instructions.append("# requirements.txt missing; skipping dependency installation")
    instructions.append("COPY . .")
    instructions.append('CMD ["python", "-m", "app"]')
    return instructions


def docker_steps_befunge(_: Path) -> List[str]:
    return [
        "COPY . .",
        'CMD ["befunge93", "app/main.bf"]',
    ]


def test_command_java(_: Path) -> Optional[List[str]]:
    return ["mvn", "test"]


def test_command_javascript(repo_root: Path) -> Optional[List[str]]:
    package_json = repo_root / "package.json"
    try:
        data = json.loads(package_json.read_text(encoding="utf-8"))
    except (FileNotFoundError, json.JSONDecodeError):
        return None

    scripts = data.get("scripts") or {}
    if "test" in scripts:
        return ["npm", "test", "--", "--watch=false"]
    return None


def test_command_python(repo_root: Path) -> Optional[List[str]]:
    pytest_markers = [
        repo_root / "tests",
        repo_root / "test",
        repo_root / "pytest.ini",
    ]
    if any(path_exists(marker) for marker in pytest_markers):
        return ["python", "-m", "pytest"]
    return None


LANGUAGE_CONFIGS: Dict[str, LanguageConfig] = {
    "c": LanguageConfig(
        name="c",
        detector=detect_c,
        base_image_env="WHANOS_BASE_IMAGE_C",
        default_base_image="whanos-c:latest",
        test_command=test_command_none,
        dockerfile_instructions=docker_steps_c,
    ),
    "java": LanguageConfig(
        name="java",
        detector=detect_java,
        base_image_env="WHANOS_BASE_IMAGE_JAVA",
        default_base_image="whanos-java:latest",
        test_command=test_command_java,
        dockerfile_instructions=docker_steps_java,
    ),
    "javascript": LanguageConfig(
        name="javascript",
        detector=detect_javascript,
        base_image_env="WHANOS_BASE_IMAGE_JAVASCRIPT",
        default_base_image="whanos-javascript:latest",
        test_command=test_command_javascript,
        dockerfile_instructions=docker_steps_javascript,
    ),
    "python": LanguageConfig(
        name="python",
        detector=detect_python,
        base_image_env="WHANOS_BASE_IMAGE_PYTHON",
        default_base_image="whanos-python:latest",
        test_command=test_command_python,
        dockerfile_instructions=docker_steps_python,
    ),
    "befunge": LanguageConfig(
        name="befunge",
        detector=detect_befunge,
        base_image_env="WHANOS_BASE_IMAGE_BEFUNGE",
        default_base_image="whanos-befunge:latest",
        test_command=test_command_none,
        dockerfile_instructions=docker_steps_befunge,
    ),
}


def detect_language(repo_root: Path) -> LanguageConfig:
    matches = []
    for language, config in LANGUAGE_CONFIGS.items():
        if config.detector(repo_root):
            matches.append((language, config))

    if not matches:
        raise OrchestratorError(
            "Unable to detect repository language. "
            "Make sure the repo contains exactly one of: "
            "Makefile, pom.xml, package.json, requirements.txt, app/main.bf."
        )

    if len(matches) > 1:
        langs = ", ".join(lang for lang, _ in matches)
        raise OrchestratorError(
            f"Repository matches multiple language detectors: {langs}. "
            "Ensure it only meets one language criterion."
        )

    return matches[0][1]


def resolve_base_image(config: LanguageConfig) -> str:
    return os.environ.get(config.base_image_env, config.default_base_image)


def build_test_in_container(
    config: LanguageConfig,
    repo_root: Path,
    *,
    skip_tests: bool,
) -> None:
    if skip_tests:
        return

    test_command = config.test_command(repo_root)
    if not test_command:
        print(f"No test command configured for {config.name}; skipping test phase.")
        return

    base_image = resolve_base_image(config)
    command = [
        "docker",
        "run",
        "--rm",
        "-v",
        f"{repo_root}:/app",
        "-w",
        "/app",
        base_image,
        *test_command,
    ]
    print(f"Running tests in {base_image}: {' '.join(test_command)}")
    run_command(command)


def render_dockerfile(
    config: LanguageConfig,
    repo_root: Path,
    *,
    extra_snippet: Optional[str],
) -> str:
    base_image = resolve_base_image(config)

    instructions = [
        "# Generated by Whanos orchestrator. Do not edit.",
        f"FROM {base_image}",
        "WORKDIR /app",
        *config.dockerfile_instructions(repo_root),
    ]

    if extra_snippet:
        instructions.append("")
        instructions.append("# --- Begin repository-provided customizations ---")
        instructions.append(extra_snippet.strip())
        instructions.append("# --- End repository-provided customizations ---")

    return "\n".join(instructions) + "\n"


def locate_customizations(repo_root: Path) -> Dict[str, Optional[Path]]:
    overrides = {
        "override": repo_root / "whanos" / "Dockerfile.override",
        "append": repo_root / "whanos" / "Dockerfile.append",
    }
    return {name: path if path_exists(path) else None for name, path in overrides.items()}


def docker_login(registry: Optional[str]) -> None:
    if not registry:
        return
    username = os.environ.get("WHANOS_REGISTRY_USERNAME")
    password = os.environ.get("WHANOS_REGISTRY_PASSWORD")

    if not username or not password:
        print(
            "Registry credentials not provided; assuming docker login already performed.",
            file=sys.stderr,
        )
        return

    print(f"Logging into registry {registry} as {username}")
    try:
        subprocess.run(
            [
                "docker",
                "login",
                registry,
                "-u",
                username,
                "--password-stdin",
            ],
            input=password,
            text=True,
            capture_output=True,
            check=True,
        )
    except subprocess.CalledProcessError as exc:
        raise OrchestratorError(
            f"Docker login failed for registry {registry}: {exc.stderr}"
        ) from exc


def build_image(
    repo_root: Path,
    *,
    dockerfile_path: Path,
    image_ref: str,
    build_args: Optional[List[str]],
) -> None:
    command = [
        "docker",
        "build",
        "-f",
        str(dockerfile_path),
        "-t",
        image_ref,
    ]
    if build_args:
        for arg in build_args:
            command.extend(["--build-arg", arg])
    command.append(str(repo_root))
    print(f"Building image {image_ref}")
    run_command(command)


def push_image(image_ref: str) -> None:
    print(f"Pushing image {image_ref}")
    run_command(["docker", "push", image_ref])


def parse_args(argv: Optional[List[str]] = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Whanos build orchestrator")
    parser.add_argument(
        "--repo",
        default=".",
        help="Path to the repository to build (default: current directory).",
    )
    parser.add_argument(
        "--image",
        required=True,
        help="Fully qualified image reference to build and push (e.g., registry.example.com/org/app:tag).",
    )
    parser.add_argument(
        "--skip-tests",
        action="store_true",
        help="Skip running language-specific test suites before the build.",
    )
    parser.add_argument(
        "--no-push",
        action="store_true",
        help="Build the image but do not push it to the registry.",
    )
    parser.add_argument(
        "--build-arg",
        action="append",
        dest="build_args",
        default=[],
        help="Additional --build-arg to pass through to docker build (can be specified multiple times).",
    )
    parser.add_argument(
        "--registry",
        help="Registry hostname (used for docker login). Defaults to the hostname portion of --image.",
    )
    return parser.parse_args(argv)


def extract_registry(image_ref: str) -> Optional[str]:
    if "/" not in image_ref:
        return None
    registry_candidate = image_ref.split("/")[0]
    if "." in registry_candidate or ":" in registry_candidate:
        return registry_candidate
    return None


def main(argv: Optional[List[str]] = None) -> int:
    args = parse_args(argv)

    repo_root = Path(args.repo).resolve()
    if not repo_root.is_dir():
        raise OrchestratorError(f"Repository path does not exist: {repo_root}")

    config = detect_language(repo_root)
    print(f"Detected language: {config.name}")

    customizations = locate_customizations(repo_root)

    dockerfile_override = customizations["override"]
    dockerfile_append = customizations["append"]

    if dockerfile_override:
        dockerfile_content = dockerfile_override.read_text()
        print(f"Using repository-provided Dockerfile override: {dockerfile_override}")
    else:
        append_snippet = dockerfile_append.read_text() if dockerfile_append else None
        dockerfile_content = render_dockerfile(config, repo_root, extra_snippet=append_snippet)

    with tempfile.NamedTemporaryFile("w", delete=False, suffix=".Dockerfile") as tmp:
        tmp.write(dockerfile_content)
        tmp_path = Path(tmp.name)

    try:
        build_test_in_container(config, repo_root, skip_tests=args.skip_tests)

        registry = args.registry or extract_registry(args.image)
        docker_login(registry)

        build_image(
            repo_root,
            dockerfile_path=tmp_path,
            image_ref=args.image,
            build_args=args.build_args,
        )

        if not args.no_push:
            push_image(args.image)
        else:
            print("Skipping image push (--no-push specified)")
    finally:
        try:
            tmp_path.unlink(missing_ok=True)
        except OSError:
            pass

    print("Build pipeline completed successfully.")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except OrchestratorError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        sys.exit(1)
