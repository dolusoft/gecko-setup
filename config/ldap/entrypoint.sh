#!/bin/bash
set -e
TEMPLATE="/tmp/bootstrap.ldif.template"
TARGET="/container/service/slapd/assets/config/bootstrap/ldif/custom/50-bootstrap.ldif"
if [ -f "$TEMPLATE" ]; then
    sed "s|\${SHARED_PASSWORD}|${SHARED_PASSWORD}|g" "$TEMPLATE" > "$TARGET"
fi
exec /container/tool/run "$@"
