#!/usr/bin/env bash
set -euo pipefail

readonly DEFAULT_LOCATION="germanywestcentral"
readonly DEFAULT_VM_SIZE="Standard_B2as_v2"
readonly DEFAULT_IMAGE="Debian:debian-13:13-gen2:latest"
readonly RG_PREFIX="evilian-"
readonly CREATOR_TAG="evilian"

LOCATION="$DEFAULT_LOCATION"
VM_SIZE="$DEFAULT_VM_SIZE"
VM_IMAGE="$DEFAULT_IMAGE"

ALLOWED_IP=""
PROJECT_NAME=""
RESOURCE_GROUP=""
VM_NAME=""
NSG_NAME=""
PUBLIC_IP=""
ADMIN_USERNAME=""
ADMIN_PASSWORD=""

# Ensure Azure CLI uses the current session's context instead of creating .azure in the working directory.
AZURE_CONFIG_DIR="${AZURE_CONFIG_DIR:-$HOME/.azure}"
export AZURE_CONFIG_DIR

declare -ar CLOUDFLARE_IPV4_RANGES=(
    "103.21.244.0/22"
    "103.22.200.0/22"
    "103.31.4.0/22"
    "104.16.0.0/13"
    "104.24.0.0/14"
    "108.162.192.0/18"
    "131.0.72.0/22"
    "141.101.64.0/18"
    "162.158.0.0/15"
    "172.64.0.0/13"
    "173.245.48.0/20"
    "188.114.96.0/20"
    "190.93.240.0/20"
    "197.234.240.0/22"
    "198.41.128.0/17"
)

declare -ar CLOUDFLARE_IPV6_RANGES=(
    "2400:cb00::/32"
    "2606:4700::/32"
    "2803:f800::/32"
    "2405:b500::/32"
    "2405:8100::/32"
    "2a06:98c0::/29"
    "2c0f:f248::/32"
)

usage() {
    cat <<EOF
Usage: ./evilian.sh -r <allowed-ip/cidr> -name <project-name> [options]

Required
  -r, --range, -range       CIDR or single IP allowed inbound through the NSG (e.g. 203.0.113.5/32)
  -name, --name, -n         Project name used for resource naming (e.g. evil123)

Optional
      --location            Azure location (default: ${LOCATION})
      --vm-size             Azure VM SKU (default: ${VM_SIZE})
      --image               Azure image URN (default: ${VM_IMAGE})
  -h, --help                Show this help and exit

Example:
  ./evilian.sh -r 93.228.224.58/32 -name evil123
EOF
}

display_message() {
    local message="$1"
    local color="${2:-}"
    case "$color" in
        red) printf '\033[91m%s\033[0m\n' "$message" ;;
        green) printf '\033[92m%s\033[0m\n' "$message" ;;
        yellow) printf '\033[93m%s\033[0m\n' "$message" ;;
        blue) printf '\033[94m%s\033[0m\n' "$message" ;;
        *) printf '%s\n' "$message" ;;
    esac
}

require_command() {
    local cmd="$1"
    if ! command -v "$cmd" >/dev/null 2>&1; then
        display_message "Missing required command: $cmd" "red"
        exit 1
    fi
}

check_azure_authentication() {
    if ! az account show --only-show-errors >/dev/null 2>&1; then
        display_message "Authenticate to Azure first: az login --use-device-code" "red"
        exit 1
    fi
}

validate_ip_input() {
    local ip="$1"
    if [[ ! "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(/([0-9]|[1-2][0-9]|3[0-2]))?$ ]]; then
        display_message "Invalid IP/CIDR provided: $ip" "red"
        exit 1
    fi
}

validate_project_name() {
    local name="$1"
    if [[ -z "$name" ]]; then
        display_message "Project name cannot be empty." "red"
        exit 1
    fi

    if [[ ! "$name" =~ ^[a-zA-Z0-9-]+$ ]]; then
        display_message "Project name must contain only letters, numbers, or hyphens." "red"
        exit 1
    fi
}

generate_random_password() {
    tr -dc 'A-Za-z0-9!@#%^&*' < /dev/urandom | head -c 24 || true
}

generate_random_username() {
    local suffix
    suffix=$(tr -dc 'a-z0-9' < /dev/urandom | head -c 6 || true)
    printf 'evil%s' "$suffix"
}

warn_old_resource_groups() {
    local groups=()
    while IFS= read -r group; do
        [[ -n "$group" ]] && groups+=("$group")
    done < <(az group list --query "[?tags.createdBy=='${CREATOR_TAG}'].name" -o tsv)

    if [[ "${#groups[@]}" -eq 0 ]]; then
        display_message "No older resource groups tagged by this script were found." "green"
        return
    fi

    for group in "${groups[@]}"; do
        display_message "Existing resource group created by this script detected: $group" "yellow"
        while true; do
            read -r -p "Delete resource group '$group'? [y/N]: " answer
            case "${answer:-n}" in
                [Yy])
                    display_message "Deleting resource group '$group'..." "blue"
                    az group delete --name "$group" --yes --no-wait --only-show-errors >/dev/null
                    display_message "Deletion initiated for '$group'." "green"
                    break
                    ;;
                [Nn]|"")
                    display_message "Keeping resource group '$group'." "green"
                    break
                    ;;
                *)
                    display_message "Please answer y or n." "yellow"
                    ;;
            esac
        done
    done
}

create_resource_group() {
    display_message "Creating resource group '$RESOURCE_GROUP' in $LOCATION..." "blue"
    az group create \
        --name "$RESOURCE_GROUP" \
        --location "$LOCATION" \
        --tags createdBy="$CREATOR_TAG" project="$PROJECT_NAME" \
        --only-show-errors >/dev/null
}

create_nsg() {
    display_message "Creating network security group '$NSG_NAME'..." "blue"
    az network nsg create \
        --name "$NSG_NAME" \
        --resource-group "$RESOURCE_GROUP" \
        --location "$LOCATION" \
        --only-show-errors >/dev/null
}

configure_nsg_rules() {
    local allowed_ip="$1"

    display_message "Configuring NSG rules (SSH restricted to $allowed_ip; Cloudflare HTTP/HTTPS allowed; temporary allow-all) ..." "blue"

    az network nsg rule create \
        --resource-group "$RESOURCE_GROUP" \
        --nsg-name "$NSG_NAME" \
        --name "AllowEvilianSSH" \
        --priority 200 \
        --direction Inbound \
        --access Allow \
        --protocol Tcp \
        --source-address-prefixes "$allowed_ip" \
        --source-port-ranges '*' \
        --destination-address-prefixes '*' \
        --destination-port-ranges 22 \
        --only-show-errors >/dev/null

    az network nsg rule create \
        --resource-group "$RESOURCE_GROUP" \
        --nsg-name "$NSG_NAME" \
        --name "AllowCloudflareWebIPv4" \
        --priority 300 \
        --direction Inbound \
        --access Allow \
        --protocol Tcp \
        --source-address-prefixes "${CLOUDFLARE_IPV4_RANGES[@]}" \
        --source-port-ranges '*' \
        --destination-address-prefixes '*' \
        --destination-port-ranges 80 443 \
        --only-show-errors >/dev/null

    az network nsg rule create \
        --resource-group "$RESOURCE_GROUP" \
        --nsg-name "$NSG_NAME" \
        --name "AllowCloudflareWebIPv6" \
        --priority 310 \
        --direction Inbound \
        --access Allow \
        --protocol Tcp \
        --source-address-prefixes "${CLOUDFLARE_IPV6_RANGES[@]}" \
        --source-port-ranges '*' \
        --destination-address-prefixes '*' \
        --destination-port-ranges 80 443 \
        --only-show-errors >/dev/null

    az network nsg rule create \
        --resource-group "$RESOURCE_GROUP" \
        --nsg-name "$NSG_NAME" \
        --name "AllowTemporaryAll" \
        --priority 900 \
        --direction Inbound \
        --access Allow \
        --protocol '*' \
        --source-address-prefixes '*' \
        --source-port-ranges '*' \
        --destination-address-prefixes '*' \
        --destination-port-ranges '*' \
        --only-show-errors >/dev/null

    az network nsg rule create \
        --resource-group "$RESOURCE_GROUP" \
        --nsg-name "$NSG_NAME" \
        --name "DenyAllInbound" \
        --priority 1000 \
        --direction Inbound \
        --access Deny \
        --protocol '*' \
        --source-address-prefixes '*' \
        --source-port-ranges '*' \
        --destination-address-prefixes '*' \
        --destination-port-ranges '*' \
        --only-show-errors >/dev/null
}

wait_for_vm_power_state() {
    local desired_state="$1"
    local message="$2"

    display_message "$message" "blue"
    while true; do
        local state
        state=$(az vm get-instance-view \
            --resource-group "$RESOURCE_GROUP" \
            --name "$VM_NAME" \
            --query "instanceView.statuses[?starts_with(code,'PowerState/')].code" \
            -o tsv)

        if [[ "$state" == "$desired_state" ]]; then
            display_message "VM reached state $desired_state." "green"
            break
        fi

        display_message "Current state: ${state:-unknown}. Waiting 15 seconds..." "yellow"
        sleep 15
    done
}

wait_for_vm_agent_ready() {
    display_message "Waiting for VM agent to report ProvisioningState/succeeded ..." "blue"
    while true; do
        local agent_status
        agent_status=$(az vm get-instance-view \
            --resource-group "$RESOURCE_GROUP" \
            --name "$VM_NAME" \
            --query "instanceView.vmAgent.statuses[?code=='ProvisioningState/succeeded'].displayStatus" \
            -o tsv)

        if [[ "$agent_status" == "Ready" ]]; then
            display_message "VM agent is Ready." "green"
            return
        fi

        display_message "VM agent still provisioning. Sleeping 30 seconds..." "yellow"
        sleep 30
    done
}

is_remote_pkg_manager_busy() {
    local context="$1"
    local stdout
    stdout=$(az vm run-command invoke \
        --resource-group "$RESOURCE_GROUP" \
        --name "$VM_NAME" \
        --command-id RunShellScript \
        --scripts "if pgrep -x apt >/dev/null || pgrep -x apt-get >/dev/null || pgrep -x aptitude >/dev/null || pgrep -x dpkg >/dev/null; then echo true; else echo false; fi" \
        --query "value[?code=='ComponentStatus/StdOut/succeeded'].message | [0]" \
        -o tsv \
        --only-show-errors | tr -d '\r')

    if [[ "$stdout" == "true" ]]; then
        display_message "apt/dpkg is busy on the VM (${context})." "yellow"
        return 0
    fi

    display_message "apt/dpkg is idle on the VM (${context})." "green"
    return 1
}

wait_for_remote_pkg_manager_idle() {
    local context="$1"
    display_message "Checking for apt/dpkg activity on the VM (${context})..." "blue"
    local attempts=18
    for ((i=1; i<=attempts; i++)); do
        if is_remote_pkg_manager_busy "$context"; then
            display_message "apt/dpkg still running (${context}); waiting 20 seconds (attempt ${i}/${attempts})..." "yellow"
            sleep 20
        else
            return 0
        fi
    done

    display_message "Continuing even though apt/dpkg still appeared busy after waiting (${context})." "yellow"
}

bootstrap_vm_to_kali() {
    display_message "Switching apt sources to Kali rolling and installing required tools..." "blue"
    local tempfile
    tempfile=$(mktemp)
    cat <<'SCRIPT' > "$tempfile"
#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

log() {
    printf '[evilian-bootstrap] %s\n' "$*"
}

ensure_sudo() {
    if command -v sudo >/dev/null 2>&1; then
        sudo "$@"
    else
        "$@"
    fi
}

log "Checking for interrupted dpkg state..."
ensure_sudo dpkg --configure -a || true

wait_for_pkg_managers() {
    local attempts=30
    for ((i=1; i<=attempts; i++)); do
        if pgrep -x apt >/dev/null || pgrep -x apt-get >/dev/null || pgrep -x aptitude >/dev/null || pgrep -x dpkg >/dev/null; then
            log "Package manager busy (attempt ${i}/${attempts}); sleeping 10s..."
            sleep 10
        else
            log "Package manager is idle."
            return 0
        fi
    done

    log "Proceeding even though package manager still appears busy."
}

wait_for_pkg_managers

ensure_sudo install -d -m 0755 /usr/share/keyrings
if ! command -v curl >/dev/null 2>&1 || ! command -v gpg >/dev/null 2>&1; then
    log "Refreshing package index before installing curl/gpg..."
    ensure_sudo apt update -y
fi
if ! command -v curl >/dev/null 2>&1; then
    log "Installing curl..."
    ensure_sudo apt install -y curl
fi
if ! command -v gpg >/dev/null 2>&1; then
    log "Installing gnupg..."
    ensure_sudo apt install -y gnupg
fi

log "Adding Kali archive key..."
ensure_sudo curl -fsSL https://archive.kali.org/archive-key.asc -o /tmp/kali-key.asc
ensure_sudo gpg --dearmor -o /usr/share/keyrings/kali-archive-keyring.gpg /tmp/kali-key.asc
ensure_sudo rm -f /tmp/kali-key.asc

log "Switching /etc/apt/sources.list to Kali rolling..."
ensure_sudo cp /etc/apt/sources.list "/etc/apt/sources.list.bak-$(date +%s)"
ensure_sudo tee /etc/apt/sources.list >/dev/null <<'EOF'
#deb http://deb.debian.org/debian bookworm main contrib non-free non-free-firmware
#deb-src http://deb.debian.org/debian bookworm main contrib non-free non-free-firmware

#deb http://security.debian.org/debian-security bookworm-security main contrib non-free non-free-firmware
#deb-src http://security.debian.org/debian-security bookworm-security main contrib non-free non-free-firmware

#deb http://deb.debian.org/debian bookworm-updates main contrib non-free non-free-firmware
#deb-src http://deb.debian.org/debian bookworm-updates main contrib non-free non-free-firmware

#deb http://http.kali.org/kali kali-rolling main contrib non-free non-free-firmware
deb [signed-by=/usr/share/keyrings/kali-archive-keyring.gpg] http://http.kali.org/kali kali-rolling main contrib non-free non-free-firmware
EOF

log "Updating package lists (apt update)..."
ensure_sudo apt update -y
log "Installing curl, git, evilginx2, jq, and htop via apt..."
ensure_sudo apt install -y curl git evilginx2 screen jq htop

log "Waiting for apt/dpkg to settle after installations..."
wait_for_pkg_managers

if command -v evilginx2 >/dev/null 2>&1; then
    log "evilginx2 is installed and on PATH."
elif command -v evilginx >/dev/null 2>&1; then
    log "evilginx binary found on PATH."
else
    log "ERROR: evilginx2 not found after installation."
    exit 1
fi
SCRIPT

    az vm run-command invoke \
        --resource-group "$RESOURCE_GROUP" \
        --name "$VM_NAME" \
        --command-id RunShellScript \
        --scripts @"$tempfile" \
        --only-show-errors

    rm -f "$tempfile"
}

retrieve_public_ip() {
    PUBLIC_IP=$(az vm show \
        --resource-group "$RESOURCE_GROUP" \
        --name "$VM_NAME" \
        -d \
        --query "publicIps" \
        -o tsv)
}

retry_install_after_reboot() {
    display_message "Re-running evilginx2/tool installation after reboot..." "blue"
    az vm run-command invoke \
        --resource-group "$RESOURCE_GROUP" \
        --name "$VM_NAME" \
        --command-id RunShellScript \
        --scripts "sudo dpkg --configure -a && sudo apt update -y && sudo apt install -y curl git evilginx2 jq htop" \
        --only-show-errors
}

wait_for_ssh() {
    local attempts=20
    for ((i=1; i<=attempts; i++)); do
        if command -v timeout >/dev/null 2>&1; then
            if timeout 5 bash -c "echo > /dev/tcp/${PUBLIC_IP}/22" >/dev/null 2>&1; then
                display_message "SSH port is reachable." "green"
                return 0
            fi
        else
            if bash -c "echo > /dev/tcp/${PUBLIC_IP}/22" >/dev/null 2>&1; then
                display_message "SSH port is reachable." "green"
                return 0
            fi
        fi
        display_message "SSH not reachable yet (attempt ${i}/${attempts}). Sleeping 10s..." "yellow"
        sleep 10
    done
    display_message "SSH port did not open in time." "red"
    return 1
}

print_connection_details() {
    cat <<EOF

Connect to your VM with the following details:
  Resource Group : $RESOURCE_GROUP
  VM Name        : $VM_NAME
  Location       : $LOCATION
  Public IP      : $PUBLIC_IP
  Username       : $ADMIN_USERNAME
  Password       : $ADMIN_PASSWORD

Suggested SSH command:
  sshpass -p "$ADMIN_PASSWORD" ssh -o StrictHostKeyChecking=no "$ADMIN_USERNAME@$PUBLIC_IP"  -t "screen -DR"
EOF
}

attempt_auto_ssh() {
    if ! command -v sshpass >/dev/null 2>&1; then
        display_message "sshpass not installed; showing SSH command instead of auto-connecting." "yellow"
        print_connection_details
        return
    fi

    display_message "Attempting automatic SSH login using sshpass..." "blue"
    if sshpass -p "$ADMIN_PASSWORD" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 "$ADMIN_USERNAME@$PUBLIC_IP" -t "screen -DR"; then
        display_message "SSH session closed." "green"
    else
        display_message "Automatic SSH attempt failed. Use the suggested command manually." "red"
        print_connection_details
    fi
}

parse_args() {
    if [[ $# -eq 0 ]]; then
        usage
        exit 1
    fi

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -r|--range|-range)
                ALLOWED_IP="$2"
                shift 2
                ;;
            -name|--name|-n)
                PROJECT_NAME="$2"
                shift 2
                ;;
            --location)
                LOCATION="$2"
                shift 2
                ;;
            --vm-size)
                VM_SIZE="$2"
                shift 2
                ;;
            --image)
                VM_IMAGE="$2"
                shift 2
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                display_message "Unknown argument: $1" "red"
                usage
                exit 1
                ;;
        esac
    done

    if [[ -z "$ALLOWED_IP" || -z "$PROJECT_NAME" ]]; then
        display_message "Missing required arguments." "red"
        usage
        exit 1
    fi
}

main() {
    parse_args "$@"
    require_command az
    validate_ip_input "$ALLOWED_IP"
    PROJECT_NAME=$(echo "$PROJECT_NAME" | tr '[:upper:]' '[:lower:]')
    validate_project_name "$PROJECT_NAME"
    check_azure_authentication

    RESOURCE_GROUP="${RG_PREFIX}${PROJECT_NAME}-rg"
    VM_NAME="${RG_PREFIX}${PROJECT_NAME}-vm"
    NSG_NAME="${RG_PREFIX}${PROJECT_NAME}-nsg"

    warn_old_resource_groups

    if az group exists --name "$RESOURCE_GROUP" --only-show-errors | grep -iq true; then
        display_message "Resource group '$RESOURCE_GROUP' already exists. Choose a different project name." "red"
        exit 1
    fi

    ADMIN_USERNAME=$(generate_random_username)
    ADMIN_PASSWORD=$(generate_random_password)

    create_resource_group
    create_nsg
    configure_nsg_rules "$ALLOWED_IP"

    display_message "Starting VM deployment..." "blue"
    PUBLIC_IP=$(az vm create \
        --resource-group "$RESOURCE_GROUP" \
        --name "$VM_NAME" \
        --image "$VM_IMAGE" \
        --size "$VM_SIZE" \
        --nsg "$NSG_NAME" \
        --admin-username "$ADMIN_USERNAME" \
        --admin-password "$ADMIN_PASSWORD" \
        --authentication-type password \
        --enable-secure-boot false \
        --public-ip-sku Standard \
        --tags createdBy="$CREATOR_TAG" project="$PROJECT_NAME" \
        --only-show-errors \
        --query "publicIpAddress" \
        -o tsv)

    wait_for_vm_power_state "PowerState/running" "Waiting for VM to enter 'running' state..."
    wait_for_vm_agent_ready
    wait_for_remote_pkg_manager_idle "before bootstrap"
    bootstrap_vm_to_kali
    wait_for_remote_pkg_manager_idle "after bootstrap"

    display_message "Pausing 60 seconds before reboot to ensure package operations are settled..." "yellow"
    sleep 60
    display_message "Rebooting VM after bootstrap tasks..." "blue"
    az vm restart --resource-group "$RESOURCE_GROUP" --name "$VM_NAME" --only-show-errors >/dev/null
    wait_for_vm_power_state "PowerState/running" "Waiting for VM to finish reboot after bootstrap..."
    wait_for_vm_agent_ready
    retry_install_after_reboot
    retrieve_public_ip

    print_connection_details
    if wait_for_ssh; then
        attempt_auto_ssh
    else
        display_message "Skipping automatic SSH because the port is still closed." "yellow"
    fi
}

main "$@"
