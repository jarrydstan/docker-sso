#!/bin/bash
### CI/CD Script for docker-sso ###
set -euo pipefail
export COMPOSE_FILE=docker-compose.yaml:docker-compose.ci.yaml

# Check if the .env file exists
cp example.env .env
mkdir ./cloudflare
touch ./cloudflare/credentials && chmod 600 ./cloudflare/credentials

# Start the services
echo "Starting services..."
docker compose up -d --wait

docker compose down
# docker compose rm -f 
docker system prune -af 1> /dev/null

rm .env 
rm -rf ./cloudflare ./gitlab custom-templates current_email certs letsencrypt
echo "CI/CD Script for docker-sso completed"