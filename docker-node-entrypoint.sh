#!/bin/sh
set -eu

cd /var/www/html

runtime_env="${NODE_ENV:-${APP_ENV:-local}}"

# Always ensure dependencies are present in the containerized workflow.
if [ -f package-lock.json ]; then
    npm ci
else
    npm install
fi

case "$runtime_env" in
    production|prod)
        echo "[node] Environment: $runtime_env. Running production build..."
        npm run build
        ;;
    *)
        echo "[node] Environment: $runtime_env. Starting Vite dev server..."
        exec npm run dev -- --host 0.0.0.0 --port "${VITE_PORT:-5173}"
        ;;
esac
