import json
import os
import build.builder as builder

if __name__ == "__main__":
    org = os.getenv("TFTASK_GH_ORG", "galleybytes")
    host = os.getenv("TFTASK_CONTAINER_REGISTRY_HOST", "ghcr.io")
    containerfile = os.getenv("TFTASK_CONTAINERFILE", "containerfiles/infrakube-task.Containerfile")
    platform = os.getenv("TFTASK_PLATFORM", "linux/amd64,linux/arm64")
    build_context = "."
    image = os.getenv("TFTASK_IMAGE", "infrakube-task")
    tag = os.getenv("TFTASK_TAG", "latest")
    push = os.getenv("TFTASK_PUSH", "true").lower() == "true"
    cache_from = os.getenv("TFTASK_CACHE_FROM")
    cache_to = os.getenv("TFTASK_CACHE_TO")
    token = os.getenv("GITHUB_TOKEN") or exit("ERROR: GITHUB_TOKEN is missing!")

    if push:
        builder.docker_login_task("galleybytes", "ghcr.io", token)
    builder.build_task(
        containerfile,
        platform,
        False,
        [],
        build_context,
        host,
        org,
        image,
        tag,
        push=push,
        cache_from=cache_from,
        cache_to=cache_to,
    )
