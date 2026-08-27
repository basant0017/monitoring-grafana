#!/usr/bin/env bash
# Alias — run client monitoring install (STEP 1 on client, STEP 2 manual on monitoring server).
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/install-client-monitoring.sh" "$@"
