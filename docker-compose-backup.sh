#!/usr/bin/env bash

#https://gist.githubusercontent.com/pirate/265e19a8a768a48cf12834ec87fb0eed/raw/4347a57c1264e47393c8879b811d309168a702e0/docker-compose-backup.sh
#https://gist.github.com/pirate/265e19a8a768a48cf12834ec87fb0eed

### Bash Environment Setup
# http://redsymbol.net/articles/unofficial-bash-strict-mode/
# https://www.gnu.org/software/bash/manual/html_node/The-Set-Builtin.html
# set -o xtrace
set -o errexit
set -o errtrace
set -o nounset
set -o pipefail
IFS=$'\n'


# Set DOCKER=podman if you want to use podman instead of docker
DOCKER="${DOCKER:-docker}"

# Detect native platform
PLATFORM_ARCH=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/;s/armv7l/arm\/v7/')
DOCKER_PLATFORM="linux/${PLATFORM_ARCH}"

IMAGE="${IMAGE:-ubuntu:24.04}"

verbose="" # "-v"

# Check dependencies
if ! command -v jq &> /dev/null; then
    echo "Error: 'jq' is not installed. Please install it to use this script."
    exit 1
fi

select_project() {
    echo "Fetching running Docker Compose projects..."
    
    local projects_json
    projects_json=$($DOCKER compose ls --format json)

    if [ -z "$projects_json" ] || [ "$projects_json" == "[]" ]; then
        echo "No running docker-compose projects found."
        exit 1
    fi

    # Parse JSON using jq
    local project_names
    local config_files
    
    # We use jq to extract arrays. IFS is newline in this script, so this works.
    project_names=($(echo "$projects_json" | jq -r '.[].Name'))
    config_files=($(echo "$projects_json" | jq -r '.[].ConfigFiles'))

    echo "Select a project to backup:"
    local i=1
    for name in "${project_names[@]}"; do
        # Just show the first config file if there are many
        local cf="${config_files[$((i-1))]}"
        echo "$i) $name (${cf%%,*})"
        ((i++))
    done

    local selection
    # Reset IFS for read to work normally for user input
    echo -n "Enter selection number: "
    local old_ifs="$IFS"
    IFS=$' \t\n' read -r selection
    IFS="$old_ifs"

    if [[ "$selection" =~ ^[0-9]+$ ]] && [ "$selection" -ge 1 ] && [ "$selection" -le "${#project_names[@]}" ]; then
        local idx=$((selection-1))
        local config_file="${config_files[$idx]}"
        
        # Handle comma separated config files
        config_file="${config_file%%,*}"
        
        selected_project_dir=$(dirname "$config_file")
        selected_project_name="${project_names[$idx]}"
    else
        echo "Invalid selection."
        exit 1
    fi
}


get_services() {
    local project_name="$1"



    local services

    # tenta via compose config

    # fallback: via containers existentes
    services=$(docker ps -a \
        --filter "label=com.docker.compose.project=$project_name" \
        --format '{{.Names}}' \
        | sort -u)
    if [ $? -eq 0 ] && [ -n "$services" ]; then
        echo "$services"
        return 0
    fi
    
    # pushd "$project_dir" > /dev/null

    # services=$(
    #     $DOCKER compose \
    #         --project-name "$project_name" \
    #         config --services 2>/dev/null
    # )
    # if [ $? -eq 0 ] && [ -n "$services" ]; then
    #     echo "$services"
    #     return 0
    # fi

    # popd > /dev/null
}

# We use .Destination since we're using --volumes-from
FILTER_BOTH='{{ range .Mounts }}{{ printf "%v\x00" .Destination }}{{ end }}'
FILTER_BIND='{{ range .Mounts }}{{ if eq .Type "bind" }}{{ printf "%v\x00" .Destination }}{{ end }}{{ end }}'
FILTER_VOLUME='{{ range .Mounts }}{{ if eq .Type "volume" }}{{ printf "%v\x00" .Destination }}{{ end }}{{ end }}'

get_volumes () {
    local CONTAINER="$1"
	$DOCKER inspect --type container -f "$FILTER_VOLUME" "$CONTAINER" | head -c -1 | sort -uz
}

save_volumes () {
    local CONTAINER="$1"
    local TAR_FILE="$2"
	if [ -f "$TAR_FILE" ] ; then
		echo "ERROR: $TAR_FILE already exists" >&2
		exit 1
	fi
	umask 077
	# Create a void tar file to avoid mounting its directory as a volume
	touch -- "$TAR_FILE"
	tmp_dir=$(mktemp -du -p /)
	get_volumes "$CONTAINER" | $DOCKER run --rm -i --platform "$DOCKER_PLATFORM" --volumes-from "$CONTAINER" -e LC_ALL=C.UTF-8 -v "$TAR_FILE:/${tmp_dir}/${TAR_FILE##*/}" "$IMAGE" tar -c -a $verbose --null -T- -f "/${tmp_dir}/${TAR_FILE##*/}"
}


perform_backup() {
    local input_dir="$1"
    local force_project_name="${2:-}"

    echo "[*] Starting backup for project at $input_dir with project name '$force_project_name'"

    if [ ! -d "$input_dir" ]; then
         echo "[X] Error: $input_dir is not a directory."
         exit 1
    fi
 
    # Resolve absolute path
    local project_dir
    project_dir=$(cd "$input_dir" && pwd)

    if [ -f "$project_dir/docker-compose.yml" ]; then
        echo "[i] Found docker-compose config at $project_dir/docker-compose.yml"
    else
        echo "[X] Could not find a docker-compose.yml file in $project_dir"
        exit 1
    fi
    
    # Move to project directory
    pushd "$project_dir" > /dev/null

    local project_name
    if [ -n "$force_project_name" ]; then
        project_name="$force_project_name"
    else
        project_name=$(basename "$project_dir")
    fi

    local backup_time
    backup_time=$(date +"%Y-%m-%d_%H-%M-%S")
    local backup_dir="$project_dir/backups/$project_name/$backup_time"

    # Source any needed environment variables
    [ -f "$project_dir/docker-compose.env" ] && source "$project_dir/docker-compose.env"
    [ -f "$project_dir/.env" ] && source "$project_dir/.env"


    echo "[+] Backing up $project_name project to $backup_dir"
    mkdir -p "$backup_dir"

    echo "    - Saving docker-compose.yml config"
    cp "$project_dir/docker-compose.yml" "$backup_dir/docker-compose.yml"

    # Optional: pause the containers before backing up to ensure consistency
    # $DOCKER compose pause

    # Optional: run a command inside the contianer to dump your application's state/database to a stable file
    # echo "    - Saving application state to ./dumps"
    # mkdir -p "$backup_dir/dumps"
    # your database/stateful service export commands to run inside docker go here, e.g.
    #   $DOCKER compose exec postgres env PGPASSWORD="$POSTGRES_PASSWORD" pg_dump -U "$POSTGRES_USER" "$POSTGRES_DB" | gzip -9 > "$backup_dir/dumps/$POSTGRES_DB.sql.gz"
    #   $DOCKER compose exec redis redis-cli SAVE
    #   $DOCKER compose exec redis cat /data/dump.rdb | gzip -9 > "$backup_dir/dumps/redis.rdb.gz"

    COMPOSE_PROJECT_NAME=${project_name}


    local services=$(get_services "$project_name")
    echo "[*] Found services: $services"
    for service_name in $services; do
        

        image_id=$($DOCKER inspect -f '{{.Image}}' $service_name)
        image_name=$($DOCKER image inspect --format '{{json .RepoTags}}' "$image_id" | jq -r '.[0]')
        container_id=$($DOCKER inspect -f '{{.Id}}' $service_name)

        echo "[*] Backing up service: $service_name (image: $image_name, container: ${container_id:-none})"

        service_dir="$backup_dir/$service_name"
        echo "[*] Backing up ${project_name} | ${service_name} to ./$service_name..."
        mkdir -p "$service_dir"
        
        # save image
        echo "    - Saving $image_name image to ./$service_name/image.tar"
        $DOCKER save --output "$service_dir/image.tar" "$image_id"
        
        if [[ -z "$container_id" ]]; then
            echo "    - Warning: $service_name has no container yet."
            echo "         (has it been started at least once?)"
            continue
        fi

        # save config
        echo "    - Saving container config to ./$service_name/config.json"
        $DOCKER inspect "$container_id" > "$service_dir/config.json"

        # save logs
        echo "    - Saving stdout/stderr logs to ./$service_name/docker.{out,err}"
        $DOCKER logs "$container_id" > "$service_dir/docker.out" 2> "$service_dir/docker.err"


        save_volumes "$container_id" "$service_dir/volumes.tar"
        # # save data volumes
        # mkdir -p "$service_dir/volumes"
        # for source in $($DOCKER inspect -f '{{range .Mounts}}{{println .Source}}{{end}}' "$container_id"); do
        #     if [ -z "$source" ] || [ ! -e "$source" ]; then
        #         echo "    - Warning: Skipping invalid volume source '$source' not exists"
        #         continue
        #     fi
        #         volume_dir="$service_dir/volumes$source"
        #         echo "    - Saving $source volume to ./$service_name/volumes$source"
        #         mkdir -p "$(dirname "$volume_dir")"
        #         cp -a -r "$source" "$volume_dir"
        # done

        # save container filesystem
        echo "    - Saving container filesystem to ./$service_name/container.tar"
        $DOCKER export --output "$service_dir/container.tar" "$container_id"

        # # save entire container root dir
        # echo "    - Saving container root to $service_dir/root"
        # cp -a -r "/var/lib/docker/containers/$container_id" "$service_dir/root"
    done

    echo "[*] Compressing backup folder to $backup_dir.tar.gz"
    tar -zcf "$backup_dir.tar.gz" --totals "$backup_dir" && rm -Rf "$backup_dir"

    echo "[√] Finished Backing up $project_name to $backup_dir.tar.gz."
    
    popd > /dev/null
}

# START MAIN EXECUTION
if [ "$#" -ge 1 ]; then
    # User provided arguments, usage: ./script <project_dir>
    # In this case we infer project name from directory name
    perform_backup "${1:-$PWD}"
else
    # Interactive mode
    select_project
    perform_backup "$selected_project_dir" "$selected_project_name"
fi

# Resume the containers if paused above
# $DOCKER compose unpause