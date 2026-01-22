#!/bin/sh
set -e

echo "Starting Frontend Entrypoint..."
echo "Environment check:"
echo "Original API_BASE_URL='$API_BASE_URL'"
echo "Original DNS_RESOLVER='$DNS_RESOLVER'"

# 1. Fix API_BASE_URL protocol
# Check if URL starts with http:// or https://
case "$API_BASE_URL" in
  http://*|https://*)
    echo "API_BASE_URL has protocol."
    ;;
  *)
    echo "API_BASE_URL missing protocol. Prepending http://"
    # Assuming http for internal service communication if protocol is missing
    export API_BASE_URL="http://$API_BASE_URL"
    ;;
esac

# 2. Fix DNS_RESOLVER
# If set to default Docker local IP (127.0.0.11) but running in an environment 
# where that might not work (like Render), try to detect system DNS.
if [ "$DNS_RESOLVER" = "127.0.0.11" ]; then
    DETECTED_DNS=$(awk '/nameserver/ {print $2; exit}' /etc/resolv.conf)
    echo "Detected system DNS: $DETECTED_DNS"
    
    if [ -n "$DETECTED_DNS" ] && [ "$DETECTED_DNS" != "127.0.0.11" ]; then
        echo "Overriding default DNS_RESOLVER with detected system DNS: $DETECTED_DNS"
        export DNS_RESOLVER="$DETECTED_DNS"
    elif [ -z "$DETECTED_DNS" ]; then
        echo "No system DNS detected. Fallback to Google DNS (8.8.8.8)"
        export DNS_RESOLVER="8.8.8.8"
    fi
    # If detected is 127.0.0.11, we keep it (local docker case)
fi

echo "Final API_BASE_URL='$API_BASE_URL'"
echo "Final DNS_RESOLVER='$DNS_RESOLVER'"

if [ -z "$API_BASE_URL" ]; then
    echo "ERROR: API_BASE_URL is missing or empty!"
    exit 1
fi

echo "Generating Nginx configuration..."
# Usamos envsubst con lista explícita de variables para no romper $uri, $host, etc.
envsubst '${API_BASE_URL} ${DNS_RESOLVER}' < /etc/nginx/default.conf.tpl > /etc/nginx/conf.d/default.conf

echo "Configuration generated. verification:"
grep "proxy_pass" /etc/nginx/conf.d/default.conf
grep "resolver" /etc/nginx/conf.d/default.conf

echo "Starting Nginx..."
exec nginx -g 'daemon off;'
