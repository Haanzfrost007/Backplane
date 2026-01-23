FROM nginx:alpine

# Install curl and bind-tools (nslookup) for health checks and DNS debugging
RUN apk add --no-cache curl bind-tools

# No copiamos a /etc/nginx/templates/ para evitar el envsubst automático que rompe variables de nginx ($uri, $1)
COPY default.conf.template /etc/nginx/default.conf.tpl
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
COPY index.html /usr/share/nginx/html/index.html

# Valores por defecto para desarrollo local
ENV API_BASE_URL=http://api-gateway:8080
ENV DNS_RESOLVER=127.0.0.11

EXPOSE 80

CMD ["/entrypoint.sh"]