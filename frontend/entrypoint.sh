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
HOST_WITHOUT_PROTO=$(echo $API_BASE_URL | sed 's|http://||' | sed 's|https://||')
HOSTNAME_ONLY=$(echo $HOST_WITHOUT_PROTO | cut -d: -f1)
PORT_ONLY=$(echo $HOST_WITHOUT_PROTO | cut -d: -f2 -s)

# Default port if missing
if [ -z "$PORT_ONLY" ]; then
    PORT_ONLY="80"
fi

echo "Resolving host: $HOSTNAME_ONLY (Port: $PORT_ONLY)"

# Wait loop (max 60 seconds)
i=0
RESOLVED_IP=""
while [ $i -lt 60 ]; do
    # Try dig first (cleaner output)
    if [ -x "$(command -v dig)" ]; then
        RESOLVED_IP=$(dig +short "$HOSTNAME_ONLY" | head -n1)
    fi
    
    # Fallback to nslookup if dig failed or returned empty
    if [ -z "$RESOLVED_IP" ]; then
        RESOLVED_IP=$(nslookup "$HOSTNAME_ONLY" 2>/dev/null | awk '/^Address: / { print $2 }' | head -n1)
    fi

    if [ -n "$RESOLVED_IP" ]; then
         echo "✅ Host $HOSTNAME_ONLY resolved to IP: $RESOLVED_IP"
         break
    fi
    
    # Debug every 10s
    if [ $((i % 10)) -eq 0 ]; then
        echo "🔍 Debug: Resolution failed for $HOSTNAME_ONLY"
        nslookup "$HOSTNAME_ONLY" || true
    fi

    echo "⏳ Waiting for $HOSTNAME_ONLY to be resolvable... ($i/60)"
    sleep 1
    i=$((i+1))
done

if [ -z "$RESOLVED_IP" ]; then
    echo "❌ ERROR: Could not resolve $HOSTNAME_ONLY after 60s. Nginx will likely fail."
    # Fallback to original hostname hoping Nginx can see it later (unlikely)
    RESOLVED_UPSTREAM="$API_BASE_URL"
else
    # Construct URL with IP to bypass Nginx resolver issues
    RESOLVED_UPSTREAM="http://$RESOLVED_IP:$PORT_ONLY"
    echo "🎯 using Resolved Upstream: $RESOLVED_UPSTREAM"
fi

# --- 3. GENERATE CONFIG FILE ---
# We use cat with EOF to avoid sed issues.
# We escape \$ for Nginx variables that should NOT be substituted by shell.
# IMPORTANT: We use the RESOLVED IP address in proxy_pass.
# This bypasses Nginx's resolver limitations with search domains.

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
        
        # Direct proxy_pass using the RESOLVED IP
        proxy_pass $RESOLVED_UPSTREAM;
        
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
