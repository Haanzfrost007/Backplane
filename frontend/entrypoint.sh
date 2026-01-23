#!/bin/sh
set -e

echo "Starting Frontend Entrypoint (Wait-for-Host Mode)..."

# --- 1. ENV VAR SETUP ---

# Fix API_BASE_URL
if [ -z "$API_BASE_URL" ]; then
    echo "WARNING: API_BASE_URL is empty. Defaulting to internal service."
    export API_BASE_URL="http://api-gateway:10000"
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
    export API_BASE_URL="http://api-gateway:10000"
fi

echo "----------------------------------------"
echo "CONFIGURING NGINX WITH:"
echo "API_BASE_URL = $API_BASE_URL"
echo "----------------------------------------"

# --- 2. CONFIGURE RESOLVER ---
# Detect system DNS (critical for Render internal domains)
DNS_RESOLVER=$(awk '/nameserver/ {print $2; exit}' /etc/resolv.conf)

if [ -z "$DNS_RESOLVER" ]; then
    echo "⚠️  WARNING: No DNS resolver found in /etc/resolv.conf. Defaulting to Google DNS (8.8.8.8)."
    echo "    Internal service names like 'api-gateway' WILL NOT RESOLVE."
    DNS_RESOLVER="8.8.8.8"
else
    echo "✅ Detected System DNS: $DNS_RESOLVER"
fi

# --- 3. GENERATE CONFIG FILE ---
# We use cat with EOF to avoid sed issues.
# We escape \$ for Nginx variables that should NOT be substituted by shell.
# STRATEGY: Runtime Resolution.
# We use a variable for proxy_pass to force Nginx to resolve the hostname at REQUEST time,
# not at STARTUP time. This prevents "host not found" crashes if the API Gateway is slow to start.

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
        # Use the detected system resolver
        resolver $DNS_RESOLVER valid=10s ipv6=off;
        
        # Strip /api/ prefix
        rewrite ^/api/(.*) /\$1 break;
        
        # Runtime variable trick:
        # Nginx won't crash at startup if this host is missing.
        # It will try to resolve it only when a request comes in.
        # IMPORTANT: Use direct string interpolation to avoid "uninitialized variable" errors
        set \$upstream_host "api-gateway";
        set \$upstream_port "10000";
        set \$upstream_proto "http";
        
        proxy_pass \$upstream_proto://\$upstream_host:\$upstream_port;
        
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_cache_bypass \$http_upgrade;
        proxy_ssl_server_name on;
        
        # Error handling
        proxy_intercept_errors on;
        error_page 502 = @backend_down;
    }
    
    location @backend_down {
        default_type application/json;
        return 502 '{"error": "Bad Gateway", "message": "Backend ($API_BASE_URL) is not resolvable or unreachable. It might be starting up. Retry in a few seconds."}';
    }
}
EOF

# --- 4. VERIFY AND START ---

echo "Generated Config Content:"
cat /etc/nginx/conf.d/default.conf

echo "Starting Nginx (Runtime Resolution Mode)..."
exec nginx -g 'daemon off;'
