#!/usr/bin/env bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPS="$SCRIPT_DIR/configs/projects.yaml"
SERVERS="$SCRIPT_DIR/configs/servers.yaml"
PROJECTS_DATA="$SCRIPT_DIR/configs/projects-data.yaml"
DATA_STORES="$SCRIPT_DIR/configs/data-stores.yaml"
KEYS="$SCRIPT_DIR/keys"

[[ -f "$SCRIPT_DIR/.env" ]] && source "$SCRIPT_DIR/.env"
gh_token="${GITHUB_TOKEN}"
[[ -z "$gh_token" ]] && { echo -e "${RED}✗ GITHUB_TOKEN not set${RESET}"; exit 1; }
gh_username="$GITHUB_USERNAME"
if [ -z "$gh_username" ]; then
    gh_username=$(getent passwd "$USER" | cut -d: -f5 | cut -d, -f2)
    gh_username=$(echo "$gh_username" | tr '[:upper:]' '[:lower:]')
fi
[[ -z "$gh_username" ]] && { echo -e "${RED}✗ GITHUB_USERNAME not set${RESET}"; exit 1; }

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; RESET='\033[0m'

app_field()    { yq e ".[] | select(.name == \"$1\") | .$2" "$APPS"    | grep -v '^null$'; }
server_field() { yq e ".[] | select(.name == \"$1\") | .$2" "$SERVERS" | grep -v '^null$'; }
data_field() { yq e ".[] | select(.project == \"$1\") | .$2" "$PROJECTS_DATA" | grep -v '^null$'; }
store_field() { yq e ".[] | select(.name == \"$1\") | .$2" "$DATA_STORES" | grep -v '^null$'; }

build_ssh_opts() {
    local server=$1

    local ip=$(server_field "$server" ip)
    local srv_user=$(server_field "$server" user)
    local key=$(server_field "$server" key)

    TARGET="${ip:-$server}"
    if [[ -n "$srv_user" ]]; then
        TARGET="$srv_user@$ip"
    fi

    SSH_OPTS=(-o StrictHostKeyChecking=no -o BatchMode=yes)
    [[ -n "$key" ]] && SSH_OPTS+=(-i "$KEYS/$key")
}

upload_to_s3() {
    local store=$1
    local file=$2
    echo "  Uploading to $store..."

    local bucket=$(store_field "$store" bucket)
    local endpoint=$(store_field "$store" endpoint)
    local key_id=$(store_field "$store" key_id)
    local key_secret=$(store_field "$store" key_secret)
 
    ssh "${SSH_OPTS[@]}" "$TARGET" "rclone copyto /tmp/$file ':s3,provider=Cloudflare,access_key_id=${key_id},secret_access_key=${key_secret}:${bucket}/${file}' --s3-endpoint=${endpoint} --s3-region=auto --s3-no-check-bucket --quiet"
}

setup_server() {
    #local ssh_opts="$1"
    local deploy_dir="$1"
    local gh_username="$2"

    echo -e "${YELLOW}Setting up $TARGET...${RESET}"

    ssh "${SSH_OPTS[@]}" "$TARGET" << EOF
set -e

# Docker
if ! command -v docker &>/dev/null; then
    echo "  Installing Docker..."
    curl -fsSL https://get.docker.com | sh
    systemctl enable --now docker
fi

docker --version || { echo "Docker install failed"; exit 1; }

# rclone
if ! command -v rclone &>/dev/null; then
    curl https://rclone.org/install.sh | sudo bash
fi

if ! command -v caddy &>/dev/null; then
    echo "  Installing Caddy..."
    apt-get install -y debian-keyring debian-archive-keyring apt-transport-https curl
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
        | gpg --dearmor --batch --yes -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
        | tee /etc/apt/sources.list.d/caddy-stable.list
    apt-get update -qq
    apt-get install -y caddy
    systemctl enable --now caddy
fi

# Ensure Caddyfile exists
if [ ! -f /etc/caddy/Caddyfile ]; then
    echo "# Managed by prax" > /etc/caddy/Caddyfile
fi

# Create deploy user
if ! id deploy &>/dev/null; then
    echo "  Creating deploy user..."
    useradd -m -s /bin/bash deploy
fi
usermod -s /bin/bash deploy
usermod -aG docker deploy

# App dirs
mkdir -p "$deploy_dir"
chown deploy:deploy "$deploy_dir"

EOF

ssh "${SSH_OPTS[@]}" "$TARGET" << 'EOF'
COMMON_SERVICES=("nginx" "apache2" "httpd" "lighttpd")
for svc in "${COMMON_SERVICES[@]}"; do
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
        echo "  Found active $svc. Stopping and disabling..."
        systemctl stop "$svc"
        systemctl disable "$svc"
    fi
done
systemctl enable --now caddy
EOF

ssh "${SSH_OPTS[@]}" "$TARGET" \
    "echo '$gh_token' | sudo -u deploy docker login ghcr.io -u $gh_username --password-stdin"

    echo -e "${GREEN}✓ $server setup complete${RESET}"
}

backup_app() {
    local app=$1
    echo -e "\n${YELLOW}▶ Backing up $app...${RESET}"

    local server=$(app_field "$app" server)
    [[ -z "$server" ]] && { echo -e "${RED}✗ Project '$app' not found${RESET}"; return 1; }

    local deploy_dir="/var/www/$app"
    build_ssh_opts "$server"

    # read files to backup from projects-data.yaml
    local files=$(data_field "$app" "files[]")
    [[ -z "$files" ]] && { echo -e "${RED}✗ No data files config for the project $app${RESET}"; return 1; }

    local datastore=$(data_field "$app" datastore)
    local timestamp=$(date +%Y%m%d_%H%M%S)

    local store_type=$(store_field "$datastore" "type")
    local backup_path="${app}/${timestamp}.tar.gz"

    # build tar arguments
    local tar_args=""
    while IFS= read -r file; do
        tar_args="$tar_args $file"
    done <<< "$files"

    echo "  Creating archive on server..."
    ssh "${SSH_OPTS[@]}" "$TARGET" << EOF
mkdir -p /tmp/$app
cd $deploy_dir
tar czf /tmp/$backup_path $tar_args
echo "  Archive created: /tmp/$backup_path"
EOF

    upload_to_${store_type} "$datastore" "$backup_path" 

    # cleanup
    ssh "${SSH_OPTS[@]}" "$TARGET" "rm -f /tmp/$backup_path"

    echo -e "${GREEN}✓ Backup completed${RESET}"
}

list_s3() {
    local store=$1
    local app=$2

    local bucket=$(store_field "$store" bucket)
    local endpoint=$(store_field "$store" endpoint)
    local key_id=$(store_field "$store" key_id)
    local key_secret=$(store_field "$store" key_secret)

    ssh "${SSH_OPTS[@]}" "$TARGET" "rclone lsf ':s3,provider=Cloudflare,access_key_id=${key_id},secret_access_key=${key_secret}:${bucket}/${app}' --s3-endpoint='${endpoint}' --s3-region=auto --s3-no-check-bucket 2>/dev/null"
}

list_backups() {
    local app=$1
    local datastore=$2
    local store_type=$(store_field "$datastore" type)
    echo -e "\n${YELLOW}Backups for $app:${RESET}" >&2

    local -a files
    while IFS= read -r line; do
        [[ -n "$line" ]] && files+=("$line")
    done < <(list_${store_type} "$datastore" "$app")

    if [[ ${#files[@]} -eq 0 ]]; then
        echo -e "${RED}✗ No backups found for $app${RESET}" >&2
        echo ""
        return
    fi

    # display with index
    echo -e "\n${YELLOW}Available backups for $app:${RESET}" >&2
    for i in "${!files[@]}"; do
        echo -e "  $((i+1))) ${files[$i]}" >&2
    done
    echo -e "  0) Cancel\n" >&2

    # prompt
    local selection
    read -p "Select backup to restore [0-${#files[@]}]: " selection >&2

    # validate
    if ! [[ "$selection" =~ ^[0-9]+$ ]] || [[ "$selection" -eq 0 ]]; then
        echo -e "${YELLOW}⚠ Restore cancelled${RESET}" >&2
        echo ""
        return
    fi

    if [[ "$selection" -gt ${#files[@]} ]]; then
        echo -e "${RED}✗ Invalid selection${RESET}" >&2
        echo ""
        return
    fi

    # return filename
    echo "${files[$((selection-1))]}"
}

download_from_s3() {
    local store=$1
    local file_path=$2

    local bucket=$(store_field "$store" bucket)
    local endpoint=$(store_field "$store" endpoint)
    local key_id=$(store_field "$store" key_id)
    local key_secret=$(store_field "$store" key_secret)

    echo "  Downloading from $store..."
    ssh "${SSH_OPTS[@]}" "$TARGET" "rclone copyto ':s3,provider=Cloudflare,access_key_id=${key_id},secret_access_key=${key_secret}:${bucket}/${file_path}' '/tmp/$file_path' --s3-endpoint='${endpoint}' --s3-region=auto --s3-no-check-bucket --quiet"
}

restore_app() {
    local app=$1
    echo -e "\n${YELLOW}▶ Restoring $app...${RESET}"

    local server=$(app_field "$app" server)
    [[ -z "$server" ]] && { echo -e "${RED}✗ Project '$app' not found${RESET}"; return 1; }

    local deploy_dir="/var/www/$app"
    build_ssh_opts "$server"

    # read files to backup from projects-data.yaml
    local files=$(data_field "$app" "files[]")
    [[ -z "$files" ]] && { echo -e "${RED}✗ No data files config for the project $app${RESET}"; return 1; }

    local datastore=$(data_field "$app" datastore)
    local store_type=$(store_field "$datastore" "type")

    local selected_file
    selected_file=$(list_backups "$app" "$datastore")

    [[ -z "$selected_file" ]] && return 0

    local backup_path="$app/$selected_file"
    download_from_${store_type} "$datastore" "$backup_path"

    # stop container
    echo "  Stopping app..."
    ssh "${SSH_OPTS[@]}" "$TARGET" \
        "cd $deploy_dir && docker compose down" 2>/dev/null || true

    # extract
    echo "  Restoring files..."
    ssh "${SSH_OPTS[@]}" "$TARGET" << EOF
cd $deploy_dir
tar xzf /tmp/$backup_path
chown -R deploy:deploy $deploy_dir
rm -f /tmp/$backup_path
EOF

    echo "  Starting app..."
    ssh "${SSH_OPTS[@]}" "$TARGET" \
        "sudo -u deploy bash -c 'cd $deploy_dir && docker compose up -d'"

    echo -e "${GREEN}✓ Restore completed${RESET}"
}

parse_domain_entry() {
    local entry=$1
    CONTAINER_PORT=$(echo "$entry" | cut -d: -f1)
    DOMAIN=$(echo "$entry" | cut -d: -f2)
    HOST_PORT=$(echo "$entry" | cut -d: -f3)
}

generate_port_override() {
    local app=$1
    local temp_path=$2

    local service=$(yq e '.services | keys | .[0]' "$temp_path/docker-compose.yml")

    cat > "$temp_path/docker-compose.override.yml" << EOF
services:
  $service:
    ports:
EOF

    while IFS= read -r entry; do
        parse_domain_entry "$entry"
        if [[ "$DOMAIN" == "-" ]]; then
            echo "      - \"$HOST_PORT:$CONTAINER_PORT\"" >> "$temp_path/docker-compose.override.yml"
        else
            echo "      - \"127.0.0.1:$HOST_PORT:$CONTAINER_PORT\"" >> "$temp_path/docker-compose.override.yml"
        fi
    done < <(yq e ".[] | select(.name == \"$app\") | .domains[]" "$APPS")
yq e 'del(.services[].ports)' -i "$temp_path/docker-compose.yml"
}

update_caddy() {
    local domain=$1
    local port=$2

    local caddy_block="\n"
    caddy_block+="$domain {\n    reverse_proxy localhost:$port\n}\n"
    caddy_block+="# prax:$domain:end"

    ssh "${SSH_OPTS[@]}" "$TARGET" << EOF
# remove old block
sed -i '/$domain {/,/# prax:$domain:end/d' /etc/caddy/Caddyfile 2>/dev/null || true
printf "$caddy_block\n" >> /etc/caddy/Caddyfile
caddy fmt --overwrite /etc/caddy/Caddyfile
systemctl reload caddy
EOF
}

deploy_app() {
    local app=$1
    echo -e "\n${YELLOW}▶ Deploying $app...${RESET}"

    local server=$(app_field "$app" server)
    [[ -z "$server" ]] && { echo -e "${RED}✗${RESET} Project '$app' not found in config"; return 1; }

    local repo=$(app_field "$app" repo)

    build_ssh_opts "$server"

    # --- clone ---
    local tmp=$(mktemp -d)
    trap "rm -rf $tmp" RETURN

    echo "  Cloning $repo..."
    git clone --depth=1 "$repo" "$tmp/$app" -q || {
        echo -e "${RED}✗ Clone failed${RESET}"; return 1
    }

    # --- build ---
    echo "  Building $app..."
    # docker build -t "$app" "$tmp/$app" -q
    docker build -f "$tmp/$app/Dockerfile" -t "$app" "$tmp/$app" || {
        echo -e "${RED}✗ Build failed${RESET}"; return 1
    }

    ghcr_url="ghcr.io/$gh_username/$app:latest"
    docker tag $app $ghcr_url

    echo "DEBUG: gh_username=$gh_username"
    echo "DEBUG: gh_token length=${#gh_token}"

     echo "$gh_token" | docker login ghcr.io -u "$gh_username" --password-stdin

    echo "  Pushing $app..."
    #docker push $ghcr_url -q
    docker push "$ghcr_url" -q || {
        echo -e "${RED}✗ Push failed${RESET}"
        return 1
    }

    deploy_dir="/var/www/$app"
    setup_server "$deploy_dir" "$gh_username" # $ssh_opts $target $app

    # --- deploy on VPS ---
    echo "  Deploying on $server..."

    echo "  Overriding service ports..."
    generate_port_override "$app" "$tmp/$app/"

    # copy compose file and env if not already there
    # sync docker-compose.yml and .env.example from repo
    scp "${SSH_OPTS[@]}" "$tmp/$app/docker-compose.yml" "$TARGET:$deploy_dir/docker-compose.yml"
    [ -f $tmp/$app/docker-compose.override.yml ] &&  scp "${SSH_OPTS[@]}" "$tmp/$app/docker-compose.override.yml" "$TARGET:$deploy_dir/docker-compose.override.yml"
    scp "${SSH_OPTS[@]}" "$tmp/$app/.env.example" "$TARGET:$deploy_dir/.env.example"
    ssh "${SSH_OPTS[@]}" $TARGET "sudo chown -R deploy:deploy $deploy_dir"

    ssh "${SSH_OPTS[@]}" $TARGET << ENDSSH
cd $deploy_dir
# if .env is a directory (docker created it), remove it
[ -d .env ] && rm -rf .env && echo "  Removed .env directory"
# create .env from .env.example if missing
[ ! -f .env ] && cp .env.example .env 2>/dev/null && echo "  Created .env from .env.example" || true
sudo chown -R deploy:deploy $deploy_dir
sudo -u deploy bash << INNEREOF
cd $deploy_dir
docker compose pull -q
docker compose up -d --remove-orphans
docker image prune -f
INNEREOF
ENDSSH

echo "  Configuring domains..."
while IFS= read -r entry; do
        parse_domain_entry "$entry"
        [[ "$DOMAIN" == "-" ]] && continue
        update_caddy "$DOMAIN" "$HOST_PORT"
done < <(app_field "$app" "domains[]")


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
    backup)
        app=${2}
        [[ -z "$app" ]] && { echo "usage: $0 backup <project name>"; exit 1; }
        backup_app "$app"
        ;;
    restore)
        app=${2}
        [[ -z "$app" ]] && { echo "usage: $0 restore <project name>"; exit 1; }
        restore_app "$app"
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
        echo "       $0 backup all | $0 backup project1 project2 ... "
        echo "       $0 restore all | $0 restore project1 project2 ... "
        ;;
esac
