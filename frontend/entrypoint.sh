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

# --- 2. HOST RESOLUTION CHECK ---
# Extract hostname to check connectivity
# Remove protocol (http:// or https://)
HOST_ONLY=$(echo $API_BASE_URL | sed 's|http://||' | sed 's|https://||' | cut -d: -f1)

echo "Waiting for host resolution: $HOST_ONLY"

# Wait loop (max 60 seconds)
i=0
while [ $i -lt 60 ]; do
    # Try nslookup (now installed via bind-tools)
    if nslookup "$HOST_ONLY" > /dev/null 2>&1; then
         echo "✅ Host $HOST_ONLY resolved successfully."
         break
    fi
    
    # Fallback/Debug: Show why it failed every 10 seconds
    if [ $((i % 10)) -eq 0 ]; then
        echo "🔍 Debug: nslookup output for $HOST_ONLY:"
        nslookup "$HOST_ONLY" || true
    fi

    echo "⏳ Waiting for $HOST_ONLY to be resolvable... ($i/60)"
    sleep 1
    i=$((i+1))
done

if [ $i -ge 60 ]; then
    echo "❌ ERROR: Timeout waiting for $HOST_ONLY. Starting Nginx anyway (might crash)."
fi

# --- 3. GENERATE CONFIG FILE ---
# We use cat with EOF to avoid sed issues.
# We escape \$ for Nginx variables that should NOT be substituted by shell.
# IMPORTANT: We use DIRECT proxy_pass ($API_BASE_URL) instead of variables.
# This forces Nginx to use the System Resolver (libc) at startup, which respects search domains.

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
        # Strip /api/ prefix
        rewrite ^/api/(.*) /\$1 break;
        
        # Direct proxy_pass using the substituted variable (Hardcoded at startup)
        # This uses the system resolver (supports search domains like .render.internal)
        proxy_pass $API_BASE_URL;
        
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
        return 502 '{"error": "Bad Gateway", "message": "Could not connect to API Gateway ($API_BASE_URL). Check logs."}';
    }
}
EOF

# --- 4. VERIFY AND START ---

echo "Generated Config Content:"
cat /etc/nginx/conf.d/default.conf

echo "Starting Nginx..."
exec nginx -g 'daemon off;'
