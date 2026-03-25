#!/usr/bin/env bash
# Deploy ersventaja to EC2: SSH in, pull, build, and restart the app container.
# Requires .deploy.env (copy from .deploy.env.example). Usage: ./deploy.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_ENV="$SCRIPT_DIR/.deploy.env"

if [[ ! -f "$DEPLOY_ENV" ]]; then
  echo "Missing .deploy.env. Copy .deploy.env.example to .deploy.env and set SSH_KEY, SSH_HOST, REMOTE_DIR."
  exit 1
fi

set -a && source "$DEPLOY_ENV" && set +a

if [[ -z "$SSH_KEY" || -z "$SSH_HOST" || -z "$REMOTE_DIR" ]]; then
  echo ".deploy.env must set SSH_KEY, SSH_HOST, and REMOTE_DIR."
  exit 1
fi

KEY_PATH="$SSH_KEY"
if [[ "$KEY_PATH" != /* ]]; then
  KEY_PATH="$(cd "$SCRIPT_DIR" && cd "$(dirname "$KEY_PATH")" && pwd)/$(basename "$KEY_PATH")"
fi

if [[ ! -f "$KEY_PATH" ]]; then
  echo "SSH key not found: $KEY_PATH (set in .deploy.env)"
  exit 1
fi

echo "Deploying to $SSH_HOST (dir: $REMOTE_DIR)"
ssh -i "$KEY_PATH" -o StrictHostKeyChecking=accept-new "$SSH_HOST" \
  "cd $REMOTE_DIR && REPO_PATH=\$(pwd) && sudo su -c \"cd \\\"\$REPO_PATH\\\" && git config --global --add safe.directory \\\"\$REPO_PATH\\\" && git pull && docker-compose build && docker-compose up -d ersventaja --force-recreate\""

echo "Running database migrations..."
ssh -i "$KEY_PATH" -o StrictHostKeyChecking=accept-new "$SSH_HOST" \
  "cd $REMOTE_DIR && sudo docker-compose exec -T ersventaja mix ecto.migrate"

echo "Deploy finished."
