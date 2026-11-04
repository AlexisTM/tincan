#!/usr/bin/env bash
# Usage: tool/play_version_code.sh <service-account-key.json>
# Prints the highest version code Google Play has for Tincan (0 if none).
set -euo pipefail
api=https://androidpublisher.googleapis.com/androidpublisher/v3/applications/com.aukmind.tincan
token=$(python3 -c "import os,sys,google.auth.transport.requests as r;from google.oauth2 import service_account as s;c=s.Credentials.from_service_account_file(os.path.expanduser(sys.argv[1]),scopes=['https://www.googleapis.com/auth/androidpublisher']);c.refresh(r.Request());print(c.token)" "${1:?usage: tool/play_version_code.sh <key.json>}")
h="Authorization: Bearer $token"
edit=$(curl -fsS -X POST -H "$h" "$api/edits" | jq -er .id)
trap 'curl -fsS -o /dev/null -X DELETE -H "$h" "$api/edits/$edit" || true' EXIT
curl -fsS -H "$h" "$api/edits/$edit/bundles" | jq -e '[.bundles[]?.versionCode] | max // 0'
