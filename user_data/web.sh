#!/bin/bash
set -euxo pipefail
dnf -y update
dnf -y install nginx awscli jq
systemctl enable nginx
CODE_BUCKET="__REPLACE_AT_RUNTIME__"
REGION="$(curl -s http://169.254.169.254/latest/dynamic/instance-identity/document | jq -r .region || echo "us-east-1")"
mkdir -p /usr/share/nginx/html
aws s3 sync "s3://${CODE_BUCKET}/web/" /usr/share/nginx/html --delete --region "$REGION" || true
echo "ok" > /usr/share/nginx/html/health
cat >/etc/nginx/nginx.conf <<'NGINX'
events {}
http {
  server {
    listen 80;
    root /usr/share/nginx/html;
    location / { try_files $uri /index.html; }
    location /health { return 200 'ok'; add_header Content-Type text/plain; }
    location /api/ { proxy_pass http://app.service.local:8080/; }
  }
}
NGINX
systemctl restart nginx
