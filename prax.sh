#!/usr/bin/env bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPS="$SCRIPT_DIR/configs/projects.yaml"
SERVERS="$SCRIPT_DIR/configs/servers.yaml"
KEYS="$SCRIPT_DIR/keys"

[[ -f "$SCRIPT_DIR/.env" ]] && source "$SCRIPT_DIR/.env"
gh_token="${GITHUB_TOKEN}"
[[ -z "$gh_token" ]] && { echo -e "${RED}✗ GITHUB_TOKEN not set${RESET}"; exit 1; }

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; RESET='\033[0m'

app_field()    { yq e ".[] | select(.name == \"$1\") | .$2" "$APPS"    | grep -v '^null$'; }
server_field() { yq e ".[] | select(.name == \"$1\") | .$2" "$SERVERS" | grep -v '^null$'; }

build_ssh_opts() {
    local key=$1
    SSH_OPTS=(-o StrictHostKeyChecking=no -o BatchMode=yes)
    [[ -n "$key" ]] && SSH_OPTS+=(-i "$KEYS/$key")
}

setup_server() {
    #local ssh_opts="$1"
    local target="$1"
    local deploy_dir="$2"
    local gh_username="$3"

    echo -e "${YELLOW}Setting up $target...${RESET}"

    ssh "${SSH_OPTS[@]}" "$target" << EOF
set -e

# Docker
if ! command -v docker &>/dev/null; then
    echo "  Installing Docker..."
    curl -fsSL https://get.docker.com | sh
    systemctl enable --now docker
fi

docker --version || { echo "Docker install failed"; exit 1; }

# Create deploy user
if ! id deploy &>/dev/null; then
    echo "  Creating deploy user..."
    useradd -m -s /bin/bash deploy
    usermod -aG docker deploy
fi

# App dirs
mkdir -p "$deploy_dir"
chown deploy:deploy "$deploy_dir"

echo "✓ Server ready"
EOF

ssh "${SSH_OPTS[@]}" "$target" \
    "echo '$gh_token' | sudo -u deploy docker login ghcr.io -u $gh_username --password-stdin"

    echo -e "${GREEN}✓ $server setup complete${RESET}"
}


deploy_app() {
    local app=$1
    echo -e "\n${YELLOW}▶ Deploying $app...${RESET}"

    local server=$(app_field "$app" server)
    local repo=$(app_field "$app" repo)
    [[ -z "$server" ]] && { echo -e "${RED}✗${RESET} Project '$app' not found in config"; return 1; }

    local ip=$(server_field "$server" ip)
    local srv_user=$(server_field "$server" user)
    local key=$(server_field "$server" key)

    local ssh_opts="-o StrictHostKeyChecking=no -o BatchMode=yes"
    local target="${ip:-$server}"
    if [[ -n "$key" ]]; then
    #    ssh_opts="$ssh_opts -i $KEYS/$key"
        target="$srv_user@$ip"
    fi
    build_ssh_opts "$key"

    # --- clone ---
    local tmp=$(mktemp -d)
    trap "rm -rf $tmp" RETURN

    echo "  Cloning $repo..."
    git clone --depth=1 "$repo" "$tmp/app" -q || {
        echo -e "${RED}✗ Clone failed${RESET}"; return 1
    }

    # --- build ---
    echo "  Building $app..."
    # docker build -t "$app" "$tmp/app" -q
    docker build -f "$tmp/app/Dockerfile" -t "$app" "$tmp/app" || {
        echo -e "${RED}✗ Build failed${RESET}"; return 1
    }

    gh_username=$(getent passwd "$USER" | cut -d: -f5 | cut -d, -f2)
    gh_username=$(echo "$gh_username" | tr '[:upper:]' '[:lower:]')
    ghcr_url="ghcr.io/$gh_username/$app:latest"

    # docker tag $app $ghcr_url

    echo "  Pushing $app..."
    #docker push $ghcr_url -q
    docker push "$ghcr_url" -q || {
        echo -e "${RED}✗ Push failed${RESET}"
        return 1
    }

    deploy_dir="/var/www/$app"
    setup_server "$target" "$deploy_dir" "$gh_username" # $ssh_opts $target $app

    # --- deploy on VPS ---
    echo "  Deploying on $server..."

    # copy compose file and env if not already there
    # sync docker-compose.yml from repo (but not .env — that stays on VPS)
    scp "${SSH_OPTS[@]}" "$tmp/app/docker-compose.yml" "$target:$deploy_dir/docker-compose.yml"
    ssh "${SSH_OPTS[@]}" $target "sudo chown -R deploy:deploy $deploy_dir"

    ssh "${SSH_OPTS[@]}" $target << ENDSSH
sudo -u deploy bash << 'INNEREOF'
cd $deploy_dir
docker compose pull -q
docker compose up -d --remove-orphans
docker image prune -f
INNEREOF
ENDSSH

echo -e "${GREEN}✓ $app deployed${RESET}"

}

case "${1:-}" in
    list)
        while IFS= read -r server; do
            echo -e "\n${YELLOW}$server${RESET}"
            while IFS= read -r app; do
                [[ "$(app_field "$app" server)" == "$server" ]] && \
                    echo "  • $app"
            done < <(yq e '.[].name' "$APPS")
        done < <(yq e '.[].server' "$APPS" | sort -u)
        echo
        ;;
    deploy)
        target=${2}
        if [[ "$target" == "all" ]]; then
            while IFS= read -r app; do deploy_app "$app"; done < <(yq e '.[].name' "$APPS")

        elif yq e '.[].name' "$APPS" | grep -qx "$target"; then
            # it's an app
            deploy_app "$target"
        else
            echo -e "${YELLOW}⚠${RESET} no such project"
        fi
        ;;
    *)
        echo "usage: $0 list"
        echo "       $0 deploy all | $0 deploy project1 project2 ... "
        ;;
esac
