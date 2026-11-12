#!/bin/sh
set -e

TEMPLATE="/opt/etc/raddb/clients.conf.template"
TARGET="/opt/etc/raddb/clients.conf"

if [ -f "$TEMPLATE" ]; then
    sed "s|\${SHARED_PASSWORD}|${SHARED_PASSWORD}|g" "$TEMPLATE" > "$TARGET"
    echo "[entrypoint] clients.conf generated from template with SHARED_PASSWORD"
else
    echo "[entrypoint] WARNING: clients.conf template not found at $TEMPLATE"
fi

# The secret lands inside a double-quoted FreeRADIUS string: escape \ and " and
# double % (xlat). Then escape for the sed replacement below (\, &, |).
RADIUS_REST_SECRET_ESC=$(printf '%s' "${RADIUS_REST_SECRET}" \
    | sed -e 's/[\\"]/\\&/g' -e 's/%/%%/g' \
    | sed 's/[\\&|]/\\&/g')

if [ -f "/tmp/radius-default" ]; then
    sed "s|\${RADIUS_REST_SECRET}|${RADIUS_REST_SECRET_ESC}|g" /tmp/radius-default > /opt/etc/raddb/sites-available/default
    echo "[entrypoint] sites-available/default overridden with RADIUS_REST_SECRET"
    if [ -z "${RADIUS_REST_SECRET}" ]; then
        echo "[entrypoint] WARNING: RADIUS_REST_SECRET is empty; HotspotApi must leave Radius:RestSharedSecret empty too"
    fi
fi

# -X is debug mode: it prints every request attribute, User-Password and the
# rest module's JSON body included, into `docker logs`. Run in the foreground
# with normal logging to stdout instead.
exec /opt/sbin/radiusd -f -l stdout
