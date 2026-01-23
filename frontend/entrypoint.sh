#!/bin/sh
# Trigger deployment check
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
# ALWAYS try to detect the system DNS first. This is crucial for:
# - Render internal service discovery (needs Render's internal DNS)
# - Kubernetes/Docker internal DNS
# - Local development
DETECTED_DNS=$(awk '/nameserver/ {print $2; exit}' /etc/resolv.conf)
echo "Detected system DNS from /etc/resolv.conf: $DETECTED_DNS"

if [ -n "$DETECTED_DNS" ]; then
    # If we found a nameserver in /etc/resolv.conf, USE IT.
    # This fixes the issue where 8.8.8.8 cannot resolve internal Render hostnames.
    echo "Using detected system DNS: $DETECTED_DNS"
    export DNS_RESOLVER="$DETECTED_DNS"
else
    # Fallback only if no DNS detected (rare)
    echo "WARNING: No DNS detected in /etc/resolv.conf. Falling back to 8.8.8.8"
    export DNS_RESOLVER="8.8.8.8"
fi

echo "Final API_BASE_URL='$API_BASE_URL'"
echo "Final DNS_RESOLVER='$DNS_RESOLVER'"

if [ -z "$API_BASE_URL" ]; then
    echo "ERROR: API_BASE_URL is missing or empty!"
    exit 1
fi

echo "Generating Nginx configuration..."
echo "Using API_BASE_URL='$API_BASE_URL'"

sed -e "s|__API_BASE_URL__|$API_BASE_URL|g" \
    -e "s|__DNS_RESOLVER__|$DNS_RESOLVER|g" \
    /etc/nginx/default.conf.tpl > /etc/nginx/conf.d/default.conf

echo "Verifying generated config:"
grep "set \$upstream_target" /etc/nginx/conf.d/default.conf
cat /etc/nginx/conf.d/default.conf

echo "Starting Nginx..."
exec nginx -g 'daemon off;'
