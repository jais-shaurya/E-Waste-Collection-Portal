
FROM nginx:alpine

LABEL org.opencontainers.image.title="E-Waste Collection Portal"
LABEL org.opencontainers.image.description="E-Waste collection and recycling information portal"

COPY index.html /usr/share/nginx/html/index.html

EXPOSE 80

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD wget -q -O /dev/null http://127.0.0.1/ || exit 1
