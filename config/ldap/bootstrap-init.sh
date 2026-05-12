#!/bin/sh
LDAP_HOST="${LDAP_HOST:-hotspot-openldap}"
LDAP_PORT="${LDAP_PORT:-389}"
LDAP_ADMIN_DN="${LDAP_ADMIN_DN:-cn=admin,dc=gecko,dc=local}"
BOOTSTRAP_LDIF="/bootstrap/50-bootstrap.ldif"

echo "[ldap-init] Waiting for OpenLDAP at $LDAP_HOST:$LDAP_PORT..."
until ldapsearch -x -H "ldap://$LDAP_HOST:$LDAP_PORT" -b "" -s base > /dev/null 2>&1; do
  sleep 2
done
echo "[ldap-init] OpenLDAP ready"

if [ ! -f "$BOOTSTRAP_LDIF" ]; then
  echo "[ldap-init] No bootstrap LDIF found, skipping"
  exit 0
fi

ldapadd -c -x -H "ldap://$LDAP_HOST:$LDAP_PORT" \
  -D "$LDAP_ADMIN_DN" \
  -w "$LDAP_ADMIN_PASSWORD" \
  -f "$BOOTSTRAP_LDIF" 2>&1 | grep -v "Already exists"

echo "[ldap-init] Bootstrap complete"
