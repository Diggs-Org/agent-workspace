#!/usr/bin/env bash
# Installs cloudflared (Cloudflare Tunnel) for exposing the local webhook server.
# No account required for temporary trycloudflare.com URLs.
set -euo pipefail

if command -v cloudflared &>/dev/null; then
  echo "cloudflared already installed: $(cloudflared --version)"
  exit 0
fi

echo "Installing cloudflared..."
ARCH=$(uname -m)
case "$ARCH" in
  x86_64)  FILENAME="cloudflared-linux-amd64" ;;
  aarch64) FILENAME="cloudflared-linux-arm64" ;;
  *)       echo "Unsupported architecture: $ARCH"; exit 1 ;;
esac

curl -fsSL \
  "https://github.com/cloudflare/cloudflared/releases/latest/download/${FILENAME}" \
  -o /usr/local/bin/cloudflared

chmod +x /usr/local/bin/cloudflared
echo "cloudflared installed: $(cloudflared --version)"
