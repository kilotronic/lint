#!/usr/bin/env bash
# A clean script: shellcheck finds nothing.
set -euo pipefail
name="${1:-world}"
echo "hello, $name"
