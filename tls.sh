#!/bin/bash

set -euo pipefail

OUTPUT_BASE="./cert-migration"
mkdir -p "$OUTPUT_BASE"

echo "Discovering namespaces with Ingress or HTTPProxy..."

INGRESS_NS=$(kubectl get ingress -A -o jsonpath='{.items[*].metadata.namespace}' | tr ' ' '\n')
HTTPPROXY_NS=$(kubectl get httpproxy -A -o jsonpath='{.items[*].metadata.namespace}' | tr ' ' '\n')

NAMESPACES=$(printf "%s\n%s\n" "$INGRESS_NS" "$HTTPPROXY_NS" | sort -u)

for ns in $NAMESPACES; do
  SECRET="cert${ns}"

  echo "Processing namespace: $ns (expected secret: $SECRET)"

  # Check if secret exists
  if ! kubectl get secret "$SECRET" -n "$ns" >/dev/null 2>&1; then
    echo "  -> Secret not found, skipping"
    continue
  fi

  # Check if it's actually referenced (extra safety)
  INGRESS_REF=$(kubectl get ingress -n "$ns" -o jsonpath="{.items[?(@.spec.tls[*].secretName=='$SECRET')].metadata.name}" 2>/dev/null || true)

  HTTPPROXY_REF=$(kubectl get httpproxy -n "$ns" -o jsonpath="{.items[?(@.spec.virtualhost.tls.secretName=='$SECRET')].metadata.name}" 2>/dev/null || true)

  if [ -z "$INGRESS_REF" ] && [ -z "$HTTPPROXY_REF" ]; then
    echo "  -> Secret not referenced, skipping"
    continue
  fi

  echo "  -> Secret is in use"

  OUT_DIR="$OUTPUT_BASE/$ns"
  mkdir -p "$OUT_DIR"

  # Extract key (handle both formats)
  KEY_B64=$(kubectl get secret "$SECRET" -n "$ns" -o jsonpath='{.data.tls\.key}' 2>/dev/null || true)

  if [ -z "$KEY_B64" ]; then
    KEY_B64=$(kubectl get secret "$SECRET" -n "$ns" -o jsonpath='{.data.key}' 2>/dev/null || true)
  fi

  if [ -z "$KEY_B64" ]; then
    echo "  -> No usable key field, skipping"
    continue
  fi

  echo "$KEY_B64" | base64 -d > "$OUT_DIR/full.pem"

  # Extract private key
  awk 'BEGIN {k=0} /BEGIN.*PRIVATE KEY/ {k=1} k {print} /END.*PRIVATE KEY/ {k=0}' \
    "$OUT_DIR/full.pem" > "$OUT_DIR/tls.key"

  # Extract cert chain
  awk 'BEGIN {c=0} /BEGIN CERTIFICATE/ {c=1} c {print} /END CERTIFICATE/ {c=0}' \
    "$OUT_DIR/full.pem" > "$OUT_DIR/tls.crt"

  # Validate
  if ! openssl x509 -in "$OUT_DIR/tls.crt" -noout >/dev/null 2>&1; then
    echo "  -> Invalid certificate, skipping"
    continue
  fi

  NEW_SECRET="${SECRET}-fixed"

  echo "  -> Creating new secret: $NEW_SECRET"

  kubectl create secret tls "$NEW_SECRET" \
    --cert="$OUT_DIR/tls.crt" \
    --key="$OUT_DIR/tls.key" \
    -n "$ns" \
    --dry-run=client -o yaml | kubectl apply -f -

done

echo "Done."
