#!/bin/sh
set -e

echo "Starting Frontend Entrypoint..."

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

# Strip trailing slash
API_BASE_URL=${API_BASE_URL%/}

echo "----------------------------------------"
echo "CONFIGURING NGINX WITH:"
echo "API_BASE_URL = $API_BASE_URL"
echo "----------------------------------------"

# --- 2. GENERATE CONFIG FILE ---
# We use direct substitution for proxy_pass.
# We rely on Render's 'fromService' to provide a valid, resolvable host:port.
# We trust the system resolver (libc) to handle the DNS lookup at startup.

cat > /etc/nginx/conf.d/default.conf <<EOF
server {
    listen 80;
    server_name localhost;

    # Serve static frontend files
    location / {
        root /usr/share/nginx/html;
        index index.html index.htm;
        try_files \$uri \$uri/ /index.html;
    }

    # Proxy API requests
    location /api/ {
        # Strip /api/ prefix
        rewrite ^/api/(.*) /\$1 break;
        
        # Proxy to the backend
        # We use the shell variable directly here, so it gets hardcoded in the config.
        proxy_pass $API_BASE_URL;
        
        # Headers
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_cache_bypass \$http_upgrade;
        
        # Error handling
        proxy_intercept_errors on;
        error_page 502 = @backend_down;
    }
    
    # Custom 502 page for JSON clients
    location @backend_down {
        default_type application/json;
        return 502 '{"error": "Bad Gateway", "message": "Backend service ($API_BASE_URL) is unavailable. Please check the logs."}';
    }
}
EOF

echo "✅ Nginx configuration generated."
echo "🚀 Starting Nginx..."
exec nginx -g "daemon off;"
