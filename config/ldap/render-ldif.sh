#!/bin/bash
# =============================================================================
# render-ldif.sh
# bootstrap.ldif içindeki ${SHARED_PASSWORD} placeholder'ı SSHA hash ile
# değiştirilir. Render edilmiş dosya plaintext parola İÇERMEZ.
#
# Kullanım:
#   export SHARED_PASSWORD='...'
#   ./config/ldap/render-ldif.sh
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$SCRIPT_DIR/bootstrap.ldif"
OUT_DIR="$SCRIPT_DIR/bootstrap-rendered"
OUT="$OUT_DIR/50-bootstrap.ldif"
DOCKER_IMAGE="osixia/openldap:latest"

if [ ! -f "$SRC" ]; then
  echo "[render-ldif] HATA: $SRC bulunamadı." >&2
  exit 1
fi

if [ -z "${SHARED_PASSWORD:-}" ]; then
  echo "[render-ldif] HATA: SHARED_PASSWORD env değişkeni tanımlı değil." >&2
  exit 1
fi

# slappasswd ile SSHA hash üret. --entrypoint ile osixia wrapper'ı bypass edilir.
HASH=$(printf '%s' "$SHARED_PASSWORD" \
  | docker run --rm -i --entrypoint slappasswd "$DOCKER_IMAGE" -T /dev/stdin 2>/dev/null)

if [ -z "$HASH" ] || [[ "$HASH" != \{*\}* ]]; then
  echo "[render-ldif] HATA: Şifre hash'i üretilemedi." >&2
  exit 1
fi

mkdir -p "$OUT_DIR"

# ${SHARED_PASSWORD} -> hash. envsubst sadece bu değişkeni işler.
SHARED_PASSWORD="$HASH" envsubst '${SHARED_PASSWORD}' < "$SRC" > "$OUT"
chmod 600 "$OUT"
unset HASH SHARED_PASSWORD

echo "[render-ldif] OK"