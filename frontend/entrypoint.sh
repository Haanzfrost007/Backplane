#!/bin/sh
set -e

echo "Starting Frontend Entrypoint (Robust Version)..."

# --- 1. ENV VAR SETUP ---

# Fix API_BASE_URL
if [ -z "$API_BASE_URL" ]; then
    echo "WARNING: API_BASE_URL is empty. Defaulting to internal service."
    export API_BASE_URL="http://api-gateway:8080"
fi

# Ensure protocol
case "$API_BASE_URL" in
  http://*|https://*)
    ;;
  *)
    echo "Adding http:// to API_BASE_URL"
    export API_BASE_URL="http://$API_BASE_URL"
    ;;
esac

# Sanity check
if [ "$API_BASE_URL" = "http://" ] || [ "$API_BASE_URL" = "https://" ]; then
    echo "WARNING: Invalid API_BASE_URL. Resetting to default."
    export API_BASE_URL="http://api-gateway:8080"
fi

# Fix DNS_RESOLVER
DETECTED_DNS=$(awk '/nameserver/ {print $2; exit}' /etc/resolv.conf)
if [ -n "$DETECTED_DNS" ]; then
    echo "Using system DNS: $DETECTED_DNS"
    export DNS_RESOLVER="$DETECTED_DNS"
else
    echo "Using fallback DNS: 127.0.0.11"
    export DNS_RESOLVER="127.0.0.11"
fi

echo "----------------------------------------"
echo "CONFIGURING NGINX WITH:"
echo "API_BASE_URL = $API_BASE_URL"
echo "DNS_RESOLVER = $DNS_RESOLVER"
echo "----------------------------------------"

# --- 2. GENERATE CONFIG FILE ---
# We use cat with EOF to avoid sed issues.
# We escape \$ for Nginx variables that should NOT be substituted by shell.

cat > /etc/nginx/conf.d/default.conf <<EOF
server {
    listen 80;
    server_name localhost;

    location / {
        root /usr/share/nginx/html;
        index index.html index.htm;
        try_files \$uri \$uri/ /index.html;
    }

    location /api/ {
        # Dynamic DNS Resolution (Docker internal)
        resolver $DNS_RESOLVER valid=10s ipv6=off;
        
        # Runtime variable for proxy_pass to prevent startup crash
        set \$upstream_target "$API_BASE_URL";

        # Strip /api/ prefix
        rewrite ^/api/(.*) /\$1 break;
        
        # When using variables in proxy_pass, we MUST specify the full URL (uri + args)
        # \$uri is the rewritten path (e.g., /health)
        proxy_pass \$upstream_target\$uri\$is_args\$args;
        
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_cache_bypass \$http_upgrade;
        proxy_ssl_server_name on;
    }
}
EOF

# --- 3. VERIFY AND START ---

echo "Generated Config Content:"
cat /etc/nginx/conf.d/default.conf

echo "Starting Nginx..."
exec nginx -g 'daemon off;'
