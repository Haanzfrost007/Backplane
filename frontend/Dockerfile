FROM nginx:alpine

# Copiar script de detección de DNS para que se ejecute al inicio
COPY dns_resolver.envsh /docker-entrypoint.d/10-dns-resolver.envsh
RUN chmod +x /docker-entrypoint.d/10-dns-resolver.envsh

COPY default.conf.template /etc/nginx/templates/default.conf.template
COPY index.html /usr/share/nginx/html/index.html

# Valor por defecto: Solo host (sin protocolo) para compatibilidad con Nginx
ENV API_BASE_URL=api-gateway:8080

EXPOSE 80
