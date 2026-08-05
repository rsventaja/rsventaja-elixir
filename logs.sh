#!/bin/bash
source .deploy.env
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$SSH_HOST" "cd $REMOTE_DIR && sudo docker-compose logs -f --tail=100 ersventaja"
