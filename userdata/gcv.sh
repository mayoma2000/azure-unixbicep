#!/bin/bash
# Reference bootstrap. Loaded verbatim by loadFileAsBase64() — Bicep does not interpolate it, so
# raw shell ($1, ${VAR}, $(cmd), nginx's $remote_addr) needs no escaping. Same property as
# Terraform's file(), and the reason neither side reaches for a templating function by default.
set -euo pipefail

FLEET="gcv"
ARTIFACTS="https://uvifleetartifactsprod.blob.core.windows.net/${FLEET}"

log() { echo "[$(date -Is)] $*"; }

log "bootstrap start for $FLEET"

# Identity-based download; no account keys on the box.
TOKEN=$(curl -sS -H Metadata:true \
  "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https://storage.azure.com/" \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["access_token"])')

for tarball in opt-lucee.tar.gz webroot-app.tar.gz etc-nginx.tar.gz; do
  log "fetching $tarball"
  curl -sS -f -H "Authorization: Bearer $TOKEN" -H "x-ms-version: 2021-08-06" \
    -o "/var/tmp/$tarball" "$ARTIFACTS/$tarball"
  # Every member path is relative to /, so every extract uses -C / — mixing conventions is what
  # put nightsadmin's tree at /opt/opt/lucee on the AWS side.
  tar --numeric-owner -xzf "/var/tmp/$tarball" -C /
done

systemctl enable --now nginx lucee
log "bootstrap complete"
