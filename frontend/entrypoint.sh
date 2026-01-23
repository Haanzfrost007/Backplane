#!/bin/sh
set -e

echo "=== STARTING FRONTEND ENTRYPOINT ==="
echo "Mode: Robust DNS + Public/Private Fallback"

# --- 1. DEBUG ENV VARS ---
echo ">>> RAW API_BASE_URL: '$API_BASE_URL' <<<"

if [ -z "$API_BASE_URL" ]; then
    echo "⚠️  WARNING: API_BASE_URL is NOT set by Render!"
    echo "    This suggests 'fromService: property: url' failed or service is not ready."
    echo "    Falling back to internal default: http://api-gateway:10000"
    export API_BASE_URL="http://api-gateway:10000"
else
    echo "✅ API_BASE_URL provided by environment."
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

echo ">>> FINAL API_BASE_URL: '$API_BASE_URL' <<<"

# --- 2. DETECT SYSTEM DNS ---
# We use system DNS first (127.0.0.11), then Google (8.8.8.8) as backup.
echo "Reading /etc/resolv.conf:"
cat /etc/resolv.conf

DNS_RESOLVER=$(awk '/nameserver/ {print $2; exit}' /etc/resolv.conf)

if [ -z "$DNS_RESOLVER" ]; then
    echo "⚠️  WARNING: No DNS resolver found. Using Google DNS."
    DNS_RESOLVER="8.8.8.8"
else
    echo "✅ Detected System DNS: $DNS_RESOLVER"
fi

# --- 3. GENERATE CONFIG FILE ---

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
        # 1. Use System DNS + Google DNS Fallback
        #    This maximizes chances of resolving either internal 'api-gateway' OR public 'https://...'
        resolver $DNS_RESOLVER 8.8.8.8 valid=5s ipv6=off;
        
        # 2. Lazy Resolution (Variable Trick)
        #    Prevents startup crash if host is temporarily unreachable
        set \$upstream_target "$API_BASE_URL";
        
        # 3. Strip /api/ prefix
        rewrite ^/api/(.*) /\$1 break;
        
        # 4. Proxy to the variable
        proxy_pass \$upstream_target;
        
        # SSL Support (Universal)
        proxy_ssl_server_name on;
        proxy_ssl_protocols TLSv1.2 TLSv1.3;
        
        # Headers
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        # proxy_set_header Host \$host; # COMENTADO: Dejar que Nginx establezca el Host basado en proxy_pass para soportar rutas públicas de Render
        proxy_cache_bypass \$http_upgrade;
        
        # Error handling
        proxy_intercept_errors on;
        error_page 502 504 = @backend_down;

        # Timeouts (Render Cold Start Fix)
        proxy_connect_timeout 300s;
        proxy_send_timeout 300s;
        proxy_read_timeout 300s;
    }
    
    # Custom 502 page for JSON clients
    location @backend_down {
        default_type application/json;
        return 502 '{"error": "Bad Gateway", "message": "Backend ($API_BASE_URL) is unreachable. Check logs for DNS errors."}';
    }
}
EOF

echo "✅ Nginx configuration generated."
echo "🚀 Starting Nginx..."
exec nginx -g "daemon off;"
