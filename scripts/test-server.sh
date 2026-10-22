#!/usr/bin/env bash
set -euo pipefail

# Never let tests use the server's normal recordings, even when SGF_DIR is set.
export RTGO_TEST_SGF_DIR
RTGO_TEST_SGF_DIR="$(mktemp -d "${TMPDIR:-/tmp}/rtgo-server-tests.XXXXXXXX")"
export SGF_DIR="$RTGO_TEST_SGF_DIR"
trap 'rm -rf -- "$RTGO_TEST_SGF_DIR"' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

cd "$(dirname "${BASH_SOURCE[0]}")/../server"
gleam test
