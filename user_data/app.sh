#!/bin/bash
set -euxo pipefail
dnf -y update
dnf -y install awscli git nodejs jq
CODE_BUCKET="__REPLACE_AT_RUNTIME__"
REGION="$(curl -s http://169.254.169.254/latest/dynamic/instance-identity/document | jq -r .region || echo "us-east-1")"
DB_HOST="$(aws rds describe-db-instances --region "$REGION" --query 'DBInstances[0].Endpoint.Address' --output text || echo "localhost")"
APP_DIR="/opt/app"
mkdir -p "$APP_DIR"
aws s3 sync "s3://${CODE_BUCKET}/app/" "$APP_DIR" --delete --region "$REGION" || true
cd "$APP_DIR"
if [ -f package.json ]; then
  npm install --omit=dev || true
  cat > /etc/systemd/system/app.service <<EOF
[Unit]
Description=App Tier Service
After=network.target
[Service]
WorkingDirectory=$APP_DIR
Environment=DB_HOST=${DB_HOST}
Environment=PORT=8080
ExecStart=/usr/bin/node server.js
Restart=always
User=root
[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now app
fi
