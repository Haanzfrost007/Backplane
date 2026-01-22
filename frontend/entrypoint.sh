#!/bin/sh
set -e

echo "Starting Frontend Entrypoint..."
echo "Environment check:"
echo "Original API_BASE_URL='$API_BASE_URL'"
echo "Original DNS_RESOLVER='$DNS_RESOLVER'"
echo "RENDER='$RENDER'"

# 1. Fix API_BASE_URL protocol
case "$API_BASE_URL" in
  http://*|https://*)
    echo "API_BASE_URL has protocol."
    ;;
  *)
    echo "API_BASE_URL missing protocol. Prepending http://"
    export API_BASE_URL="http://$API_BASE_URL"
    ;;
esac

# 2. Fix DNS_RESOLVER
# If running in Render, force Google DNS or verify system DNS
if [ "$RENDER" = "true" ]; then
    echo "Detected Render environment. Enforcing Google DNS (8.8.8.8) to avoid local resolver issues."
    export DNS_RESOLVER="8.8.8.8"
elif [ "$DNS_RESOLVER" = "127.0.0.11" ]; then
    # Local Docker or other environment
    DETECTED_DNS=$(awk '/nameserver/ {print $2; exit}' /etc/resolv.conf)
    echo "Detected system DNS: $DETECTED_DNS"
    
    if [ -n "$DETECTED_DNS" ] && [ "$DETECTED_DNS" != "127.0.0.11" ]; then
        export DNS_RESOLVER="$DETECTED_DNS"
    fi
fi

echo "Final API_BASE_URL='$API_BASE_URL'"
echo "Final DNS_RESOLVER='$DNS_RESOLVER'"

if [ -z "$API_BASE_URL" ]; then
    echo "ERROR: API_BASE_URL is missing or empty!"
    exit 1
fi

echo "Generating Nginx configuration using sed..."
# Usamos sed en lugar de envsubst para garantizar que usamos las variables modificadas
# y evitar problemas de comportamiento de envsubst con variables exportadas en sh/alpine.
sed -e "s|\${API_BASE_URL}|$API_BASE_URL|g" \
    -e "s|\${DNS_RESOLVER}|$DNS_RESOLVER|g" \
    /etc/nginx/default.conf.tpl > /etc/nginx/conf.d/default.conf

echo "Configuration generated. Verification:"
grep "proxy_pass" /etc/nginx/conf.d/default.conf
grep "resolver" /etc/nginx/conf.d/default.conf

echo "Starting Nginx..."
exec nginx -g 'daemon off;'
