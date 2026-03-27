#!/bin/bash
# container_runtime.sh — Shared helper: detect container runtime
#
# Source this file to set CONTAINER_RT to 'podman-hpc' or 'docker'.
# Usage: source "$(dirname "${BASH_SOURCE[0]}")/container_runtime.sh"

if command -v podman-hpc &>/dev/null; then
    CONTAINER_RT="podman-hpc"
elif command -v docker &>/dev/null; then
    CONTAINER_RT="docker"
else
    echo "ERROR: Neither podman-hpc nor docker found in PATH" >&2
    exit 1
fi
