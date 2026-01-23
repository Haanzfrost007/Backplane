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

    # Fallback to nslookup if dig failed or returned empty
    if [ -z "$RESOLVED_IP" ]; then
        RESOLVED_IP=$(nslookup "$HOSTNAME_ONLY" 2>/dev/null | awk '/^Address: / { print $2 }' | head -n1)
    fi
    
    # Fallback: Try "api-gateway" if the specific hostname fails (handles slugs)
    if [ -z "$RESOLVED_IP" ] && echo "$HOSTNAME_ONLY" | grep -q "api-gateway"; then
         echo "⚠️ Resolution failed for $HOSTNAME_ONLY. Trying fallback: api-gateway"
         FALLBACK_IP=$(nslookup "api-gateway" 2>/dev/null | awk '/^Address: / { print $2 }' | head -n1)
         if [ -n "$FALLBACK_IP" ]; then
             echo "✅ Fallback 'api-gateway' resolved to IP: $FALLBACK_IP"
             RESOLVED_IP="$FALLBACK_IP"
         fi
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

# Force loop to continue until resolution success (BLOCKING)
# This prevents Nginx from starting until we have a valid IP
if [ -z "$RESOLVED_IP" ]; then
    echo "❌ ERROR: Could not resolve $HOSTNAME_ONLY. Retrying indefinitely..."
    exec /entrypoint.sh
fi

# --- 3. GENERATE CONFIG FILE ---
# We use cat with EOF to avoid sed issues.
# We escape \$ for Nginx variables that should NOT be substituted by shell.
# STRATEGY: Hardcoded IP.
# We resolved the IP in bash, so we put it directly into the config.
# This eliminates ALL DNS and variable issues in Nginx.

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
        # No variables, no resolvers, no magic. Just the IP.
        proxy_pass http://$RESOLVED_IP:10000;
        
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
