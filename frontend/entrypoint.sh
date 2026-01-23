#!/bin/sh
set -e

echo "Starting Frontend Entrypoint (Resilient Mode)..."

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

# Fix DNS_RESOLVER - Auto-detect from /etc/resolv.conf
# We take the first nameserver found.
DETECTED_DNS=$(awk '/nameserver/ {print $2; exit}' /etc/resolv.conf)

if [ -n "$DETECTED_DNS" ]; then
    echo "Using system DNS: $DETECTED_DNS"
    export DNS_RESOLVER="$DETECTED_DNS"
else
    echo "WARNING: Could not detect DNS. Fallback to Google (might fail for internal hosts)."
    export DNS_RESOLVER="8.8.8.8"
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
        # Dynamic DNS Resolution
        # We use the detected system resolver.
        resolver $DNS_RESOLVER valid=5s ipv6=off;
        
        # Runtime variable for proxy_pass to prevent startup crash (Host not found)
        # This forces Nginx to resolve the DNS at request time, not startup time.
        set \$upstream_target "$API_BASE_URL";
        
        # Strip /api/ prefix
        rewrite ^/api/(.*) /\$1 break;
        
        # Proxy Pass using the variable
        # We must construct the full URL because variables are used.
        proxy_pass \$upstream_target\$uri\$is_args\$args;
        
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_cache_bypass \$http_upgrade;
        proxy_ssl_server_name on;
        
        # Error handling for debugging
        proxy_intercept_errors on;
        error_page 502 = @backend_down;
    }
    
    location @backend_down {
        default_type application/json;
        return 502 '{"error": "Bad Gateway", "message": "Could not resolve or connect to API Gateway ($API_BASE_URL). It might be starting up."}';
    }
}
EOF

# --- 3. VERIFY AND START ---

echo "Generated Config Content:"
cat /etc/nginx/conf.d/default.conf

echo "Starting Nginx..."
exec nginx -g 'daemon off;'
