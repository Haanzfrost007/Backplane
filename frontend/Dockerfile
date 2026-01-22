FROM nginx:alpine
COPY default.conf.template /etc/nginx/templates/default.conf.template
COPY index.html /usr/share/nginx/html/index.html
ENV API_BASE_URL=http://api-gateway:8080
EXPOSE 80
