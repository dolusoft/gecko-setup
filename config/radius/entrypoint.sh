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

if [ -f "/tmp/radius-default" ]; then
    cp /tmp/radius-default /opt/etc/raddb/sites-available/default
    echo "[entrypoint] sites-available/default overridden"
fi

exec /opt/sbin/radiusd -X
