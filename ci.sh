#!/bin/sh
### CI/CD Test Script for docker-sso ###
set -u
export COMPOSE_FILE=docker-compose.yaml:docker-compose.ci.yaml
DOCKER_EXIT_CODE=0

cleanup_job() {
    echo -e "section_start:$(date +%s):cleanup[collapsed=true]\r\e[0KCleaning up job"
    if ! docker compose down; then
        echo -e "\e[31mFailed to bring down all containers\e[0m"
        DOCKER_EXIT_CODE=3
    fi
    if ! docker system prune -af 1> /dev/null; then
        echo -e "\e[31mFailed to prune docker system\e[0m"
        DOCKER_EXIT_CODE=3
    fi
    rm .env 
    rm -rf ./cloudflare ./gitlab custom-templates current_email certs letsencrypt
    echo -e "section_end:$(date +%s):cleanup[collapsed=true]\r\e[0KCleanup completed."
}
# Check if the .env file exists
cp example.env .env
mkdir ./cloudflare
touch ./cloudflare/credentials && chmod 600 ./cloudflare/credentials

# Pull docker images
echo -e "section_start:$(date +%s):pull[collapsed=true]\r\e[0KPulling images"
echo -e "\e[33mPulling docker images...\e[0m"
docker compose pull --quiet
pull_status=$?
if [ $pull_status -eq 0 ]; then
    echo -e "\e[32mDocker images pulled successfully.\e[0m"
else
    echo -e "\e[31mDocker pull failed.\e[0m"
    DOCKER_EXIT_CODE=1
fi
echo -e "section_end:$(date +%s):pull[collapsed=true]\r\e[0K"

# Start the services
echo -e "section_start:$(date +%s):start[collapsed=true]\r\e[0KStarting containers"
echo -e "\e[33mStarting services...\e[0m"
docker compose up -d --wait --wait-timeout 600 --quiet-pull
compose_status=$?
if [ $compose_status -eq 0 ]; then
    echo -e "\e[32mDocker containers started successfully.\e[0m"
else
    echo -e "\e[31mDocker containers failed to start.\e[0m"
    docker compose logs -n 100
    docker compose ps -a
    DOCKER_EXIT_CODE=2
fi
echo -e "section_end:$(date +%s):start[collapsed=true]\r\e[0K"
cleanup_job
if [ $DOCKER_EXIT_CODE != 0 ]; then
    echo -e "\e[31mCI/CD Script for docker-sso failed, see logs for more details...\e[0m"
    exit $DOCKER_EXIT_CODE
fi
echo -e "\e[32mCI/CD Script for docker-sso completed\e[0m"
exit 0