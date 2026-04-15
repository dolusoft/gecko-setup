#!/bin/bash
set -e

# ── 1) Generate self-signed TLS certificates if missing ──────────────────
CERT_DIR="/container/service/slapd/assets/certs"
HOSTNAME="hotspot-openldap.gecko.local"

if [ ! -f "$CERT_DIR/ldap.crt" ]; then
    echo "[entrypoint] TLS certificates not found, generating..."
    mkdir -p "$CERT_DIR"
    cd "$CERT_DIR"

    openssl req -x509 -newkey rsa:4096 -nodes -days 3650 \
        -keyout ca.key -out ca.crt \
        -subj "/CN=Gecko Local CA"

    openssl req -newkey rsa:4096 -nodes \
        -keyout ldap.key -out ldap.csr \
        -subj "/CN=$HOSTNAME"

    cat > san.ext <<EOF
subjectAltName=DNS:$HOSTNAME,DNS:hotspot-openldap,DNS:localhost,IP:127.0.0.1
EOF

    openssl x509 -req -in ldap.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
        -out ldap.crt -days 3650 -extfile san.ext

    chmod 644 ca.crt ldap.crt
    chmod 640 ldap.key
    chown -R openldap:openldap .
    rm -f ldap.csr san.ext ca.srl
    cd /
    echo "[entrypoint] Certificates generated."
fi

# ── 2) Render bootstrap LDIF with env var interpolation ──────────────────
TEMPLATE="/tmp/bootstrap.ldif.template"
TARGET="/container/service/slapd/assets/config/bootstrap/ldif/custom/50-bootstrap.ldif"
if [ -f "$TEMPLATE" ]; then
    sed "s|\${SHARED_PASSWORD}|${SHARED_PASSWORD}|g" "$TEMPLATE" > "$TARGET"
fi

# ── 3) Hand off to osixia's original entrypoint ──────────────────────────
exec /container/tool/run "$@"
