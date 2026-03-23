#!/bin/bash
# setup_env.sh — Source this file to set up PKG_CONFIG_PATH for building ejfat_zmq_proxy.
#
# Usage:
#   export E2SAR_ROOT=/path/to/E2SAR   # source tree or install prefix
#   source scripts/setup_env.sh
#   cmake --preset macos                # or: linux, container
#
# After sourcing, PKG_CONFIG_PATH is assembled for your platform and E2SAR_ROOT is exported.
# Run again to refresh (e.g. after activating a different conda environment).

# Must be sourced, not executed
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "ERROR: This script must be sourced, not executed directly."
    echo "  Usage: source scripts/setup_env.sh"
    exit 1
fi

# Require E2SAR_ROOT
if [[ -z "${E2SAR_ROOT:-}" ]]; then
    echo "ERROR: E2SAR_ROOT is not set."
    echo "  Set it to your E2SAR source tree or install prefix:"
    echo "    export E2SAR_ROOT=/path/to/E2SAR"
    return 1
fi

if [[ ! -d "${E2SAR_ROOT}" ]]; then
    echo "WARNING: E2SAR_ROOT does not exist: ${E2SAR_ROOT}"
fi

_EXTRA_PKG=""

_add_pkgdir() {
    local d="$1"
    if [[ -d "$d" ]]; then
        _EXTRA_PKG="${_EXTRA_PKG:+${_EXTRA_PKG}:}${d}"
    fi
}

case "$(uname -s)" in
    Darwin)
        # Homebrew provides libzmq
        if command -v brew >/dev/null 2>&1; then
            _BREW_PREFIX="$(brew --prefix 2>/dev/null)"
            _add_pkgdir "${_BREW_PREFIX}/lib/pkgconfig"
        fi
        # Active conda environment provides gRPC, protobuf, abseil, cppzmq, Boost
        if [[ -n "${CONDA_PREFIX:-}" ]]; then
            _add_pkgdir "${CONDA_PREFIX}/lib/pkgconfig"
        fi
        ;;
    Linux)
        # Standard Linux system locations
        _add_pkgdir "/usr/local/lib/pkgconfig"
        _add_pkgdir "/usr/lib/x86_64-linux-gnu/pkgconfig"
        _add_pkgdir "/usr/lib/pkgconfig"
        # E2SAR installed layout (common patterns)
        _add_pkgdir "${E2SAR_ROOT}/lib/pkgconfig"
        _add_pkgdir "${E2SAR_ROOT}/lib/x86_64-linux-gnu/pkgconfig"
        _add_pkgdir "${E2SAR_ROOT}/lib/aarch64-linux-gnu/pkgconfig"
        ;;
esac

# Prepend to any existing PKG_CONFIG_PATH
export PKG_CONFIG_PATH="${_EXTRA_PKG}${PKG_CONFIG_PATH:+:${PKG_CONFIG_PATH}}"
export E2SAR_ROOT

echo "E2SAR_ROOT=${E2SAR_ROOT}"
echo "PKG_CONFIG_PATH=${PKG_CONFIG_PATH}"
unset _EXTRA_PKG _BREW_PREFIX
