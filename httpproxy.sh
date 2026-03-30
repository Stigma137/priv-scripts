#!/usr/bin/env bash
kubectl patch ds <daemonset-name> -n <namespace> -p '{"spec": {"template": {"spec": {"nodeSelector": {"non-existing-label": "true"}}}}}'

docker run --rm mcr.microsoft.com/mssql-tools \
 sqlcmd -S azty-cert-vmsqldb-modeloriesgo.database.windows.net \
 -U username@azty-cert-vmsqldb-modeloriesgo \
 -P password \
 -Q "SELECT 1"
set -euo pipefail

BASE_TEMPLATE="httpproxy-base.yaml"
OUTPUT_DIR="./generated-httpproxies"
mkdir -p "$OUTPUT_DIR"

# Toggle for testing
STOP_AFTER_FIRST=true

echo "Discovering namespaces with Ingress..."

NAMESPACES=$(kubectl get ingress -A -o jsonpath='{.items[*].metadata.namespace}' | tr ' ' '\n' | sort -u)

for ns in $NAMESPACES; do
  echo "========================================"
  echo "Processing namespace: $ns"

  NAME="${ns}-proxy"
  TLS_SECRET="cert${ns}"

  # Get all hosts in namespace
  HOSTS=$(kubectl get ingress -n "$ns" -o jsonpath='{.items[*].spec.rules[*].host}' 2>/dev/null | tr ' ' '\n' | sort -u)

  if [ -z "$HOSTS" ]; then
    echo "  -> No hosts found, skipping"
    continue
  fi

  for host in $HOSTS; do
    echo "  -> Host: $host"

    ROUTES=""

    # Extract all paths for this host
    kubectl get ingress -n "$ns" -o json | jq -c --arg HOST "$host" '
      .items[]
      | .spec.rules[]
      | select(.host == $HOST)
      | .http.paths[]
    ' | while read -r pathobj; do

      RAW_PATH=$(echo "$pathobj" | jq -r '.path')
      SERVICE=$(echo "$pathobj" | jq -r '.backend.service.name')
      PORT=$(echo "$pathobj" | jq -r '.backend.service.port.number')

      # --- FIX: normalize regex paths ---
      PREFIX=$(echo "$RAW_PATH" | sed -E 's/\(.*\)//')

      # Clean trailing slashes (except root)
      if [ "$PREFIX" != "/" ]; then
        PREFIX=$(echo "$PREFIX" | sed 's:/*$::')
      fi

      # Handle empty result
      if [ -z "$PREFIX" ]; then
        PREFIX="/"
      fi

      echo "    -> $RAW_PATH  ==>  $PREFIX  ->  $SERVICE:$PORT"

      # Root path special handling (no rewrite)
      if [ "$PREFIX" == "/" ]; then
        ROUTES+=$(cat <<EOF

  - conditions:
      - prefix: /
    services:
      - name: ${SERVICE}
        port: ${PORT}
EOF
)
      else
        ROUTES+=$(cat <<EOF

  - conditions:
      - prefix: ${PREFIX}
    pathRewritePolicy:
      replacePrefix:
        - prefix: ${PREFIX}
          replacement: /
    services:
      - name: ${SERVICE}
        port: ${PORT}
EOF
)
      fi

    done

    # Wait for subshell to finish (important)
    ROUTES=$(echo "$ROUTES")

    if [ -z "$ROUTES" ]; then
      echo "  -> No routes generated, skipping"
      continue
    fi

    # Sort routes by prefix length (more specific first)
    ROUTES=$(echo "$ROUTES" | awk '
      BEGIN { RS=""; ORS="\n\n" }
      {
        match($0, /prefix: ([^ \n]+)/, arr)
        print length(arr[1]) "|" $0
      }
    ' | sort -rn | cut -d'|' -f2-)

    OUTPUT_FILE="$OUTPUT_DIR/httpproxy-${ns}-$(echo $host | tr '.' '-').yaml"

    echo "  -> Generating $OUTPUT_FILE"

    sed \
      -e "s|\${NAME}|$NAME|g" \
      -e "s|\${NAMESPACE}|$ns|g" \
      -e "s|\${FQDN}|$host|g" \
      -e "s|\${TLS_SECRET}|$TLS_SECRET|g" \
      -e "s|\${ROUTES}|$ROUTES|g" \
      "$BASE_TEMPLATE" > "$OUTPUT_FILE"

    echo "  -> Applying HTTPProxy"

    kubectl apply -f "$OUTPUT_FILE"

    # Stop after first for testing
    if [ "$STOP_AFTER_FIRST" = true ]; then
      echo "Stopping after first successful HTTPProxy creation"
      exit 0
    fi

  done
done

echo "Done."


if [ "$PREFIX" = "/" ]; then
  ROUTES+=$'\n'
  ROUTES+="  - conditions:\n"
  ROUTES+="      - prefix: /\n"
  ROUTES+="    services:\n"
  ROUTES+="      - name: ${SERVICE}\n"
  ROUTES+="        port: ${PORT}\n"
else
  ROUTES+=$'\n'
  ROUTES+="  - conditions:\n"
  ROUTES+="      - prefix: ${PREFIX}\n"
  ROUTES+="    pathRewritePolicy:\n"
  ROUTES+="      replacePrefix:\n"
  ROUTES+="        - prefix: ${PREFIX}\n"
  ROUTES+="          replacement: /\n"
  ROUTES+="    services:\n"
  ROUTES+="      - name: ${SERVICE}\n"
  ROUTES+="        port: ${PORT}\n"
fi
PATHS_JSON=$(kubectl get ingress -n "$ns" -o json | jq -c --arg HOST "$host" '
  .items[]
  | .spec.rules[]
  | select(.host == $HOST)
  | .http.paths[]
')

ROUTES=""

while IFS= read -r pathobj; do

  RAW_PATH=$(echo "$pathobj" | jq -r '.path')
  SERVICE=$(echo "$pathobj" | jq -r '.backend.service.name')
  PORT=$(echo "$pathobj" | jq -r '.backend.service.port.number')

  [ "$SERVICE" = "null" ] && continue
  [ "$PORT" = "null" ] && continue

  PREFIX=$(echo "$RAW_PATH" | sed -E 's/\(.*\)//')

  if [ "$PREFIX" != "/" ]; then
    PREFIX=$(echo "$PREFIX" | sed 's:/*$::')
  fi

  [ -z "$PREFIX" ] && PREFIX="/"

  echo "    -> $RAW_PATH  ==>  $PREFIX  ->  $SERVICE:$PORT"

  # 🔥 Direct append (no heredoc, no subshell)
  ROUTES+=$'\n'
  ROUTES+="  - conditions:\n"
  ROUTES+="      - prefix: ${PREFIX}\n"

  if [ "$PREFIX" != "/" ]; then
    ROUTES+="    pathRewritePolicy:\n"
    ROUTES+="      replacePrefix:\n"
    ROUTES+="        - prefix: ${PREFIX}\n"
    ROUTES+="          replacement: /\n"
  fi

  ROUTES+="    services:\n"
  ROUTES+="      - name: ${SERVICE}\n"
  ROUTES+="        port: ${PORT}\n"

done <<< "$PATHS_JSON"
awk -v NAME="$NAME" \
    -v NAMESPACE="$ns" \
    -v FQDN="$host" \
    -v TLS_SECRET="$TLS_SECRET" \
    -v ROUTES="$ROUTES" '
{
  if ($0 ~ /\$\{ROUTES\}/) {
    print ROUTES
  } else {
    gsub(/\$\{NAME\}/, NAME)
    gsub(/\$\{NAMESPACE\}/, NAMESPACE)
    gsub(/\$\{FQDN\}/, FQDN)
    gsub(/\$\{TLS_SECRET\}/, TLS_SECRET)
    print
  }
}
' "$BASE_TEMPLATE" > "$OUTPUT_FILE"
