#!/usr/bin/env bash
set -euo pipefail

KEY="${DEPLOY_KEY:-../jrventajavirginia.pem}"
HOST="${DEPLOY_HOST:-ec2-user@3.87.68.246}"
REMOTE_ENV="ersventaja/.env"
LOCAL_ENV=".env.prod"
BACKUP=".env.prod.bak.$(date +%Y%m%d_%H%M%S)"

# 1. Backup do .env local (se existir)
if [ -f "$LOCAL_ENV" ]; then
  cp "$LOCAL_ENV" "$BACKUP"
  echo "📦 backup local salvo em $BACKUP"
fi

# 2. Puxa o .env atual do servidor
echo "⬇️  puxando .env do servidor..."
scp -i "$KEY" "$HOST:$REMOTE_ENV" "$LOCAL_ENV"

# 3. Abre editor pra editar
echo "✏️  editando .env..."
${EDITOR:-nano} "$LOCAL_ENV"

# 4. Sobe e reinicia o app
echo "⬆️  subindo .env e reiniciando ersventaja..."
scp -i "$KEY" "$LOCAL_ENV" "$HOST:$REMOTE_ENV"
ssh -i "$KEY" "$HOST" \
  "cd ~/ersventaja && sudo docker-compose up -d --force-recreate ersventaja"

echo "✅ pronto! .env atualizado e app reiniciado."
