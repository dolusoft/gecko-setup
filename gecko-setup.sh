#!/bin/sh
#
# Gecko Platform Installation Script
# A curl-installable shell script for deploying the Gecko platform
#

set -e

# ============================================================================
# Configuration
# ============================================================================

VERSION="1.1.0"
INSTALL_DIR="/opt/gecko"
BASE_URL="${BASE_URL:-https://raw.githubusercontent.com/dolusoft/gecko-setup/refs/heads/main}"
# GitHub archive used to fetch the entire config/ directory in a single download
REPO_ARCHIVE_URL="${REPO_ARCHIVE_URL:-https://github.com/dolusoft/gecko-setup/archive/refs/heads/main.tar.gz}"
LOG_FILE=""
ANSIBLE_AVAILABLE=0
SKIP_ENCRYPTION=0

# Command-line options. Secrets can also be passed as environment variables of the
# same name, which keeps them out of the process list and shell history.
SERVICE_PASSWORD="${SERVICE_PASSWORD:-}"
SHARED_PASSWORD="${SHARED_PASSWORD:-}"
VAULT_PASSWORD="${VAULT_PASSWORD:-}"
DOCKERHUB_USERNAME="${DOCKERHUB_USERNAME:-dolusoftcomp}"
DOCKERHUB_TOKEN="${DOCKERHUB_TOKEN:-}"
KAFKA_EXTERNAL_HOST="${KAFKA_EXTERNAL_HOST:-}"
SKIP_KERNEL=0
SKIP_DEPS=0
INFRA_ONLY=0
NO_SYSTEMD=1
DRY_RUN=0
NON_INTERACTIVE=0
FORCE=0
VERBOSE=0

# NTP servers tried in order until one succeeds
NTP_SERVERS="pool.ntp.org time.cloudflare.com time.google.com ntp.ubuntu.com"

# ============================================================================
# Colors and Output
# ============================================================================

if [ -t 1 ]; then
    RED=$(printf '\033[0;31m')
    GREEN=$(printf '\033[0;32m')
    YELLOW=$(printf '\033[1;33m')
    BLUE=$(printf '\033[0;34m')
    BOLD=$(printf '\033[1m')
    NC=$(printf '\033[0m')
else
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    BOLD=''
    NC=''
fi

# ============================================================================
# Helper Functions
# ============================================================================

log() {
    message="$1"
    if [ -n "$LOG_FILE" ]; then
        printf "%s\n" "$message" | tee -a "$LOG_FILE"
    else
        printf "%s\n" "$message"
    fi
}

log_info() {
    if [ -n "$LOG_FILE" ]; then
        printf "${BLUE}[INFO]${NC} %s\n" "$1" | tee -a "$LOG_FILE"
    else
        printf "${BLUE}[INFO]${NC} %s\n" "$1"
    fi
}

log_success() {
    if [ -n "$LOG_FILE" ]; then
        printf "${GREEN}[OK]${NC} %s\n" "$1" | tee -a "$LOG_FILE"
    else
        printf "${GREEN}[OK]${NC} %s\n" "$1"
    fi
}

log_warning() {
    if [ -n "$LOG_FILE" ]; then
        printf "${YELLOW}[WARN]${NC} %s\n" "$1" | tee -a "$LOG_FILE"
    else
        printf "${YELLOW}[WARN]${NC} %s\n" "$1"
    fi
}

log_error() {
    if [ -n "$LOG_FILE" ]; then
        printf "${RED}[ERROR]${NC} %s\n" "$1" | tee -a "$LOG_FILE"
    else
        printf "${RED}[ERROR]${NC} %s\n" "$1"
    fi
}

log_header() {
    if [ -n "$LOG_FILE" ]; then
        printf "\n${BOLD}=== %s ===${NC}\n\n" "$1" | tee -a "$LOG_FILE"
    else
        printf "\n${BOLD}=== %s ===${NC}\n\n" "$1"
    fi
}

log_verbose() {
    if [ "$VERBOSE" -eq 1 ]; then
        if [ -n "$LOG_FILE" ]; then
            printf "${BLUE}[VERBOSE]${NC} %s\n" "$1" | tee -a "$LOG_FILE"
        else
            printf "${BLUE}[VERBOSE]${NC} %s\n" "$1"
        fi
    fi
}

validate_password() {
    password="$1"

    # Check minimum length
    if [ ${#password} -lt 12 ]; then
        printf "${RED}[ERROR]${NC} Password must be at least 12 characters long.\n"
        return 1
    fi

    # Check for at least one uppercase letter
    if ! echo "$password" | grep -q '[A-Z]'; then
        printf "${RED}[ERROR]${NC} Password must contain at least one uppercase letter.\n"
        return 1
    fi

    # Check for at least one lowercase letter
    if ! echo "$password" | grep -q '[a-z]'; then
        printf "${RED}[ERROR]${NC} Password must contain at least one lowercase letter.\n"
        return 1
    fi

    # Check for at least one digit
    if ! echo "$password" | grep -q '[0-9]'; then
        printf "${RED}[ERROR]${NC} Password must contain at least one number.\n"
        return 1
    fi

    # Check for at least one special character
    # Using a simpler approach - check if password contains anything other than alphanumeric
    if echo "$password" | grep -q '^[a-zA-Z0-9]*$'; then
        printf "%s[ERROR]%s Password must contain at least one special character.\n" "$RED" "$NC"
        return 1
    fi

    return 0
}

prompt_password() {
    prompt="$1"
    var_name="$2"

    while true; do
        printf "%s: " "$prompt"
        stty -echo
        read -r password
        stty echo
        printf "\n"

        if [ -z "$password" ]; then
            log_warning "Password cannot be empty. Please try again."
            continue
        fi

        # Validate password strength
        if ! validate_password "$password"; then
            printf "\n"
            continue
        fi

        # Confirm password
        printf "Confirm password: "
        stty -echo
        read -r password_confirm
        stty echo
        printf "\n"

        if [ "$password" != "$password_confirm" ]; then
            log_error "Passwords do not match. Please try again."
            printf "\n"
            continue
        fi

        # Safe assignment: works for passwords containing any character including ' " $ ` & < > ;
        export "$var_name=$password"
        break
    done
}

prompt_continue() {
    prompt="$1"
    printf "%s (y/n): " "$prompt"
    read -r response
    [ "$response" = "y" ] || [ "$response" = "Y" ]
}

check_command() {
    command -v "$1" >/dev/null 2>&1
}

download_file() {
    url="$1"
    dest="$2"

    if [ "$DRY_RUN" -eq 1 ]; then
        log_info "[DRY RUN] Would download: $url -> $dest"
        return 0
    fi

    log_info "Downloading: $(basename "$dest")"
    if ! curl -fsSL "$url" -o "$dest"; then
        log_error "Failed to download: $url"
        return 1
    fi
    return 0
}

detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_ID="$ID"
        OS_VERSION="$VERSION_ID"
        OS_NAME="$NAME"
    else
        log_error "Unable to detect OS. /etc/os-release not found."
        exit 1
    fi
}

check_and_sync_time() {
    if [ "$DRY_RUN" -eq 1 ]; then
        log_info "[DRY RUN] Would check and sync time via NTP. Current time: $(date)"
        return 0
    fi

    log_header "TIME CHECK"

    current_time=$(date)
    log_info "Current machine time: ${BOLD}${current_time}${NC}"

    # Query an NTP server directly via UDP, then immediately read the local clock.
    # NTP response bytes 40-43 = transmit timestamp (seconds since 1900-01-01).
    # Subtract 2208988800 to convert to Unix epoch.
    # Binary output is written to a temp file to avoid shell pipeline mangling.
    ref_epoch=""
    _ntp_tmp=$(mktemp) || { log_error "Failed to create a temporary file"; exit 1; }
    for server in $NTP_SERVERS; do
        printf '\x1b\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00' \
            | nc -u -w2 "$server" 123 > "$_ntp_tmp" 2>/dev/null || true
        # NTP uses big-endian; read 4 bytes individually and combine
        ntp_sec=$(od -An -N4 -j40 -tu1 "$_ntp_tmp" 2>/dev/null \
            | awk '{print ($1*16777216 + $2*65536 + $3*256 + $4)}')
        local_epoch=$(date -u +%s)
        if [ -n "$ntp_sec" ] && [ "$ntp_sec" -gt 2208988800 ] 2>/dev/null; then
            ref_epoch=$(( ntp_sec - 2208988800 ))
            break
        fi
    done
    rm -f "$_ntp_tmp"

    if [ -n "$ref_epoch" ]; then
        diff=$(( local_epoch - ref_epoch ))
        [ "$diff" -lt 0 ] && diff=$(( -diff ))
        if [ "$diff" -lt 5 ]; then
            log_success "System clock is accurate (offset: ${diff}s). No sync needed."
            return 0
        fi
        log_warning "Clock offset detected: ${diff}s — sync is recommended."
        prompt_msg="Clock is off by ${diff}s. Sync via NTP now? [y = sync and continue | n = abort]"
    else
        prompt_msg="The current machine time is shown above. Do you want to sync it via NTP? [y = sync and continue | n = abort]"
    fi

    if [ "$NON_INTERACTIVE" -eq 0 ]; then
        if ! prompt_continue "$prompt_msg"; then
            log_warning "Installation aborted. Please sync your system clock before re-running:"
            log_warning "  ntpdate pool.ntp.org"
            log_warning "  or: chronyd -q 'server pool.ntp.org iburst'"
            exit 1
        fi
    else
        log_info "Non-interactive mode: proceeding with NTP sync automatically."
    fi

    log_info "Attempting to sync time via NTP..."

    synced=0
    for server in $NTP_SERVERS; do
        log_info "Trying NTP server: $server"

        # Check reachability (UDP 123) with a 3-second timeout
        reachable=0
        if command -v nc >/dev/null 2>&1; then
            nc -z -w 3 -u "$server" 123 >/dev/null 2>&1 && reachable=1 || true
        else
            # Fallback: use ntpdate read-only query as reachability probe
            ntpdate -q "$server" >/dev/null 2>&1 && reachable=1 || true
        fi

        if [ "$reachable" -eq 0 ]; then
            log_warning "  Server $server is not reachable, trying next..."
            continue
        fi

        # Prefer ntpdate, fall back to chronyd one-shot
        if command -v ntpdate >/dev/null 2>&1; then
            if ntpdate -u "$server" >/dev/null 2>&1; then
                synced=1
                break
            fi
        elif command -v chronyd >/dev/null 2>&1; then
            if chronyd -q "server $server iburst" >/dev/null 2>&1; then
                synced=1
                break
            fi
        else
            # Install ntpdate then retry this server
            log_info "Installing ntpdate..."
            case "$OS_ID" in
                ubuntu|debian) apt-get install -y -qq ntpdate ;;
                rhel|rocky|centos|almalinux) yum install -y -q ntpdate ;;
                alpine) apk add --quiet chrony ;;
            esac
            if command -v ntpdate >/dev/null 2>&1; then
                if ntpdate -u "$server" >/dev/null 2>&1; then
                    synced=1
                    break
                fi
            elif command -v chronyd >/dev/null 2>&1; then
                if chronyd -q "server $server iburst" >/dev/null 2>&1; then
                    synced=1
                    break
                fi
            fi
        fi

        log_warning "  Sync via $server failed, trying next..."
    done

    if [ "$synced" -eq 0 ]; then
        log_error "Could not sync time from any NTP server. Aborting installation."
        log_error "Tried: $NTP_SERVERS"
        log_error "Please fix your system clock manually and re-run the installer."
        exit 1
    fi

    log_success "Time synchronized. New machine time: $(date)"
}

configure_docker_logging() {
    if [ "$DRY_RUN" -eq 1 ]; then
        log_info "[DRY RUN] Would configure Docker log rotation: json-file driver, max-size=10m, max-file=10"
        return 0
    fi

    log_header "DOCKER LOG ROTATION"

    DAEMON_JSON="/etc/docker/daemon.json"
    LOG_CONFIG='{\n  "log-driver": "json-file",\n  "log-opts": {\n    "max-size": "10m",\n    "max-file": "10"\n  }\n}'

    log_info "Docker log rotation will be configured with the following settings:"
    log_info "  Driver            : json-file"
    log_info "  Max size per file : 10m"
    log_info "  Max log files     : 10"
    log_info "  Config file       : $DAEMON_JSON"

    if [ -f "$DAEMON_JSON" ]; then
        log_warning "An existing Docker daemon config was found at $DAEMON_JSON:"
        log_warning "--- current content ---"
        cat "$DAEMON_JSON"
        log_warning "-----------------------"
        log_warning "The installer needs to add/overwrite log rotation settings."
        log_warning "To add them manually, merge the following into your $DAEMON_JSON:"
        log_warning '  "log-driver": "json-file",'
        log_warning '  "log-opts": { "max-size": "10m", "max-file": "10" }'

        if [ "$NON_INTERACTIVE" -eq 0 ]; then
            if ! prompt_continue "Overwrite $DAEMON_JSON with the log rotation config? [y = overwrite | n = abort to edit manually]"; then
                log_warning "Installation aborted. Merge the following into $DAEMON_JSON, then re-run the installer:"
                log_warning '  {'
                log_warning '    "log-driver": "json-file",'
                log_warning '    "log-opts": {'
                log_warning '      "max-size": "10m",'
                log_warning '      "max-file": "10"'
                log_warning '    }'
                log_warning '  }'
                log_warning "Then reload Docker: systemctl restart docker"
                exit 1
            fi
        else
            # Never overwrite the host's own Docker config silently.
            log_warning "Non-interactive mode: leaving the existing $DAEMON_JSON unchanged."
            log_warning "Merge the log rotation settings above into it manually."
            return 0
        fi
    fi

    # Ensure the Docker config directory exists before writing daemon.json
    mkdir -p "$(dirname "$DAEMON_JSON")"

    # Write (or overwrite) daemon.json
    printf "%b\n" "$LOG_CONFIG" > "$DAEMON_JSON"
    log_success "Written: $DAEMON_JSON"

    # Reload Docker daemon so settings take effect immediately
    if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet docker 2>/dev/null; then
        if systemctl reload docker 2>/dev/null || systemctl restart docker 2>/dev/null; then
            log_success "Docker daemon reloaded — log rotation is active."
        else
            log_warning "Could not reload Docker automatically. Please restart Docker manually: systemctl restart docker"
        fi
    elif command -v rc-service >/dev/null 2>&1; then
        if rc-service docker restart >/dev/null 2>&1 \
        || { rc-service docker stop >/dev/null 2>&1 && rc-service docker start >/dev/null 2>&1; }; then
            log_success "Docker daemon restarted (OpenRC) — log rotation is active."
        else
            log_warning "Could not restart Docker automatically. Please restart Docker manually: rc-service docker restart"
        fi
    else
        log_warning "Could not reload Docker automatically. Please restart Docker manually: systemctl restart docker"
    fi
}

# ============================================================================
# Argument Parsing
# ============================================================================

show_help() {
    cat <<EOF
Gecko Platform Installation Script v${VERSION}

Usage: curl -sSL ${BASE_URL}/gecko-setup.sh | sudo sh -s -- [OPTIONS]

Options:
  --service-password PW     Database and MinIO password (MongoDB, ClickHouse, Redis, MinIO)
  --shared-password PW      Cryptography and inter-service authentication
  --vault-password PW       Ansible vault password (for encrypting .env)
  --dockerhub-username U    Docker Hub user for the private Gecko images
                            (default: dolusoftcomp)
  --dockerhub-token T       Docker Hub access token (read-only is enough)
  --kafka-external-host H   Address Kafka advertises to clients outside the
                            compose network: this host's own IP or DNS name
                            (default: auto-detected from the default route)
  --install-dir DIR         Installation path (default: /opt/gecko)
  --skip-kernel             Skip sysctl tuning
  --skip-deps               Skip Docker/Ansible install
  --skip-encryption         Skip ansible-vault encryption of .env
  --infra-only              Infrastructure only (no app services)
  --enable-systemd          Create systemd/OpenRC service (not recommended)
  --dry-run                 Preview without executing
  --uninstall               Remove installation
  --force                   Force installation (override warnings)
  -y, --yes                 Non-interactive mode
  -v, --verbose             Enable verbose output for debugging
  -h, --help                Show this help

Secrets can be given as environment variables instead of options, so they do not
show up in the process list or shell history: SERVICE_PASSWORD, SHARED_PASSWORD,
VAULT_PASSWORD, DOCKERHUB_USERNAME, DOCKERHUB_TOKEN, KAFKA_EXTERNAL_HOST. Run as
root (or use sudo -E) so they are kept.

Examples:
  # Standard installation (prompts for passwords and the Docker Hub token)
  curl -sSL ${BASE_URL}/gecko-setup.sh | sudo sh

  # Non-interactive, secrets from the environment (root shell)
  export SERVICE_PASSWORD SHARED_PASSWORD DOCKERHUB_TOKEN   # set beforehand
  curl -sSL ${BASE_URL}/gecko-setup.sh | sh -s -- -y

  # Uninstall
  curl -sSL ${BASE_URL}/gecko-setup.sh | sudo sh -s -- --uninstall

EOF
}

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --service-password)
                SERVICE_PASSWORD="$2"
                shift 2
                ;;
            --shared-password)
                SHARED_PASSWORD="$2"
                shift 2
                ;;
            --vault-password)
                VAULT_PASSWORD="$2"
                shift 2
                ;;
            --dockerhub-username)
                DOCKERHUB_USERNAME="$2"
                shift 2
                ;;
            --dockerhub-token)
                DOCKERHUB_TOKEN="$2"
                shift 2
                ;;
            --kafka-external-host)
                KAFKA_EXTERNAL_HOST="$2"
                shift 2
                ;;
            --install-dir)
                INSTALL_DIR="$2"
                shift 2
                ;;
            --skip-kernel)
                SKIP_KERNEL=1
                shift
                ;;
            --skip-deps)
                SKIP_DEPS=1
                shift
                ;;
            --skip-encryption)
                SKIP_ENCRYPTION=1
                shift
                ;;
            --infra-only)
                INFRA_ONLY=1
                shift
                ;;
            --enable-systemd)
                NO_SYSTEMD=0
                shift
                ;;
            --dry-run)
                DRY_RUN=1
                shift
                ;;
            --uninstall)
                uninstall_gecko
                exit 0
                ;;
            --force)
                FORCE=1
                shift
                ;;
            -y|--yes)
                NON_INTERACTIVE=1
                shift
                ;;
            -v|--verbose)
                VERBOSE=1
                shift
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                show_help
                exit 1
                ;;
        esac
    done
}

# ============================================================================
# PHASE 1: Prerequisites
# ============================================================================

check_prerequisites() {
    log_header "PHASE 1: PREREQUISITES"

    # Check root/sudo
    if [ "$(id -u)" -ne 0 ]; then
        log_error "This script must be run as root or with sudo"
        exit 1
    fi
    log_success "Running with appropriate privileges"

    # Detect OS
    detect_os
    log_success "Detected OS: $OS_NAME"

    case "$OS_ID" in
        ubuntu|debian|rhel|rocky|centos|alpine)
            log_success "Supported OS detected"
            ;;
        *)
            log_warning "OS '$OS_ID' is not officially supported. Continue anyway?"
            if [ "$FORCE" -eq 0 ] && [ "$NON_INTERACTIVE" -eq 0 ]; then
                if ! prompt_continue "Continue"; then
                    exit 1
                fi
            fi
            ;;
    esac

    # Check and sync system time via NTP
    check_and_sync_time

    # Check port conflicts
    log_info "Checking for port conflicts..."
    ports_to_check="443 514 5100 5101 8124 9002"
    port_conflicts=0

    for port in $ports_to_check; do
        if ss -tuln 2>/dev/null | grep -q ":$port " || netstat -tuln 2>/dev/null | grep -q ":$port "; then
            log_warning "Port $port is already in use"
            port_conflicts=$((port_conflicts + 1))
        fi
    done

    if [ "$port_conflicts" -gt 0 ]; then
        log_error "Found $port_conflicts port conflicts. Please resolve before continuing."
        exit 1
    fi
    log_success "No port conflicts detected"
}

# ============================================================================
# PHASE 2: Install Dependencies
# ============================================================================

retry_repo_update() {
    local max_attempts=3
    local delay=5
    local attempt=1

    while [ $attempt -le $max_attempts ]; do
        log_verbose "Repository update attempt $attempt/$max_attempts"

        case "$OS_ID" in
            ubuntu|debian)
                if apt-get update; then
                    log_success "Repository update successful"
                    return 0
                fi
                ;;
            rhel|rocky|centos)
                if yum update -y; then
                    log_success "Repository update successful"
                    return 0
                fi
                ;;
            alpine)
                if apk update; then
                    log_success "Repository update successful"
                    return 0
                fi
                ;;
        esac

        if [ $attempt -lt $max_attempts ]; then
            log_warning "Repository update failed (attempt $attempt/$max_attempts)"
            log_info "Retrying in ${delay} seconds..."
            sleep $delay
        else
            log_error "Failed to update package repositories after $max_attempts attempts"
            log_error "Please check your internet connection and repository configuration"
            return 1
        fi

        attempt=$((attempt + 1))
    done
}

install_docker() {
    log_info "Installing Docker Engine and Docker Compose..."
    log_info "Purpose: Container runtime required for running all Gecko services"

    if [ "$DRY_RUN" -eq 1 ]; then
        log_info "[DRY RUN] Would install Docker"
        return 0
    fi

    case "$OS_ID" in
        ubuntu|debian)
            retry_repo_update || return 1
            apt-get install -y ca-certificates curl gnupg

            # Add Docker's official GPG key
            install -m 0755 -d /etc/apt/keyrings
            curl -fsSL https://download.docker.com/linux/$OS_ID/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
            chmod a+r /etc/apt/keyrings/docker.gpg

            # Set up repository
            echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$OS_ID $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null

            retry_repo_update || return 1
            apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
            ;;
        rhel|rocky|centos)
            retry_repo_update || return 1
            yum install -y yum-utils
            yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
            yum install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
            ;;
        alpine)
            retry_repo_update || return 1
            apk add docker docker-cli-compose
            ;;
        *)
            log_error "Unsupported OS for Docker installation"
            return 1
            ;;
    esac

    # Start and enable Docker
    if [ "$OS_ID" = "alpine" ]; then
        rc-update add docker boot
        rc-service docker start
    else
        systemctl enable docker
        systemctl start docker
    fi

    # Add current user to docker group if not root
    if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != "root" ]; then
        if command -v usermod >/dev/null 2>&1; then
            usermod -aG docker "$SUDO_USER"
            log_info "Added $SUDO_USER to docker group (logout/login required)"
        else
            addgroup "$SUDO_USER" docker
            log_info "Added $SUDO_USER to docker group (logout/login required)"
        fi
    fi

    # Verify installation
    if ! docker --version >/dev/null 2>&1; then
        return 1
    fi

    if ! docker compose version >/dev/null 2>&1; then
        return 1
    fi

    return 0
}

install_ansible() {
    log_info "Installing Ansible..."
    log_info "Purpose: Used to encrypt the compose.env file containing sensitive passwords"
    log_info "Note: This is recommended for security but not strictly required"

    if [ "$DRY_RUN" -eq 1 ]; then
        log_info "[DRY RUN] Would install Ansible"
        return 0
    fi

    case "$OS_ID" in
        ubuntu|debian)
            retry_repo_update || return 1
            apt-get install -y ansible
            ;;
        rhel|rocky|centos)
            retry_repo_update || return 1
            yum install -y epel-release
            yum install -y ansible
            ;;
        alpine)
            retry_repo_update || return 1
            apk add ansible
            ;;
        *)
            log_error "Unsupported OS for Ansible installation"
            return 1
            ;;
    esac

    # Verify installation
    if ansible --version >/dev/null 2>&1; then
        return 0
    fi

    return 1
}

install_dependencies() {
    log_header "PHASE 2: INSTALL DEPENDENCIES"

    if [ "$SKIP_DEPS" -eq 1 ]; then
        log_info "Skipping dependency installation (--skip-deps)"

        # Verify required dependencies exist
        if ! check_command docker || ! docker compose version >/dev/null 2>&1; then
            log_error "Docker is not installed. Cannot continue without Docker."
            exit 1
        fi

        if check_command ansible; then
            ANSIBLE_AVAILABLE=1
            log_success "Ansible is available"
        else
            log_warning "Ansible is not available - .env encryption will be skipped"
        fi

        return
    fi

    # Update package repositories
    log_info "Updating package repositories..."
    if [ "$DRY_RUN" -eq 0 ]; then
        if ! retry_repo_update; then
            log_error "Cannot continue without accessible package repositories"
            exit 1
        fi
    fi

    # Install Docker (critical)
    if ! check_command docker || ! docker compose version >/dev/null 2>&1; then
        if ! install_docker; then
            log_error "Failed to install Docker"
            log_error "Docker is critical for running Gecko services"
            log_error "Cannot continue without Docker"
            exit 1
        fi
        log_success "Docker installed successfully"
    else
        log_success "Docker is already installed"
    fi

    configure_docker_logging

    # Install Ansible (recommended, not critical)
    if ! check_command ansible; then
        if install_ansible; then
            ANSIBLE_AVAILABLE=1
            log_success "Ansible installed successfully"
        else
            log_warning "Failed to install Ansible"
            log_warning "Ansible is used to encrypt the compose.env file for security"
            log_warning "Without Ansible, your passwords will be stored in plain text"

            if [ "$NON_INTERACTIVE" -eq 0 ]; then
                if prompt_continue "Continue without Ansible encryption"; then
                    log_info "Continuing without Ansible..."
                else
                    log_info "Installation aborted by user"
                    exit 1
                fi
            else
                log_warning "Non-interactive mode: Continuing without Ansible"
            fi
        fi
    else
        ANSIBLE_AVAILABLE=1
        log_success "Ansible is already installed"
    fi
}

# ============================================================================
# PHASE 3: Kernel Tuning
# ============================================================================

configure_kernel() {
    log_header "PHASE 3: KERNEL TUNING"

    if [ "$SKIP_KERNEL" -eq 1 ]; then
        log_info "Skipping kernel tuning (--skip-kernel)"
        return
    fi

    log_info "Applying kernel parameters for optimal performance..."

    if [ "$DRY_RUN" -eq 1 ]; then
        log_info "[DRY RUN] Would apply kernel tuning"
        return
    fi

    cat > /etc/sysctl.d/99-gecko.conf <<EOF
# Gecko Platform Kernel Tuning
vm.max_map_count = 262144
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535
fs.file-max = 2097152
net.core.rmem_max = 134217728
EOF

    sysctl -p /etc/sysctl.d/99-gecko.conf
    log_success "Kernel tuning applied"
}

# ============================================================================
# PHASE 4: Setup Directories & Files
# ============================================================================

setup_directories() {
    log_header "PHASE 4: SETUP DIRECTORIES & FILES"

    # Create directories
    log_info "Creating installation directories..."
    if [ "$DRY_RUN" -eq 0 ]; then
        mkdir -p "$INSTALL_DIR/config"
        mkdir -p "$INSTALL_DIR/config/ldap"
        mkdir -p "$INSTALL_DIR/config/radius/mods-enabled"
        mkdir -p "$INSTALL_DIR/config/radius/sites-enabled"
        mkdir -p "$INSTALL_DIR/logs"
        chmod 755 "$INSTALL_DIR"
        chmod 755 "$INSTALL_DIR/config"
        chmod 755 "$INSTALL_DIR/config/ldap"
        chmod 755 "$INSTALL_DIR/config/radius"
        chmod 755 "$INSTALL_DIR/config/radius/mods-enabled"
        chmod 755 "$INSTALL_DIR/config/radius/sites-enabled"
        chmod 755 "$INSTALL_DIR/logs"
    fi
    log_success "Directories created"

    # Download config directory and compose files (entire repository in one archive)
    log_info "Downloading configuration directory and compose files from hosting server..."

    if [ "$DRY_RUN" -eq 1 ]; then
        log_info "[DRY RUN] Would download repository archive: $REPO_ARCHIVE_URL"
        log_info "[DRY RUN] Would extract config/ into $INSTALL_DIR/config"
        log_info "[DRY RUN] Would extract docker-infra-compose.yml and docker-gecko-compose.yml into $INSTALL_DIR"
    else
        _archive_tmp=$(mktemp) || { log_error "Failed to create a temporary file"; exit 1; }
        _extract_tmp=$(mktemp -d) || { log_error "Failed to create a temporary directory"; rm -f "$_archive_tmp"; exit 1; }

        # Download the repository archive
        if ! curl -fsSL "$REPO_ARCHIVE_URL" -o "$_archive_tmp"; then
            log_error "Failed to download repository archive: $REPO_ARCHIVE_URL"
            rm -rf "$_archive_tmp" "$_extract_tmp"
            exit 1
        fi

        # Extract it (archive unpacks into a single top-level dir, e.g. gecko-setup-main/)
        if ! tar -xzf "$_archive_tmp" -C "$_extract_tmp"; then
            log_error "Failed to extract repository archive"
            rm -rf "$_archive_tmp" "$_extract_tmp"
            exit 1
        fi

        # Locate the config/ directory inside the extracted tree; its parent is the repo root
        _src_config=$(find "$_extract_tmp" -maxdepth 2 -type d -name config | head -n 1)
        if [ -z "$_src_config" ]; then
            log_error "config/ directory not found inside archive"
            rm -rf "$_archive_tmp" "$_extract_tmp"
            exit 1
        fi
        _src_root=$(dirname "$_src_config")

        # Copy the whole config tree into the install directory
        cp -R "$_src_config/." "$INSTALL_DIR/config/"

        # Copy compose files from the repo root
        for _compose in docker-infra-compose.yml docker-gecko-compose.yml; do
            if [ ! -f "$_src_root/$_compose" ]; then
                log_error "$_compose not found inside archive"
                rm -rf "$_archive_tmp" "$_extract_tmp"
                exit 1
            fi
            cp "$_src_root/$_compose" "$INSTALL_DIR/$_compose"
        done

        rm -rf "$_archive_tmp" "$_extract_tmp"
    fi

    # Set permissions across the copied config tree (robust to files being added/removed)
    if [ "$DRY_RUN" -eq 0 ]; then
        # Directories traversable, regular files readable
        find "$INSTALL_DIR/config" -type d -exec chmod 755 {} +
        find "$INSTALL_DIR/config" -type f -exec chmod 644 {} +
        # Shell scripts must be executable
        find "$INSTALL_DIR/config" -type f -name '*.sh' -exec chmod 755 {} +
        # Compose files
        chmod 644 "$INSTALL_DIR"/*.yml
    fi

    log_success "Configuration files downloaded and permissions set"
}

# Validate a password given as an option or environment variable; prompted
# passwords are validated by prompt_password. Never prints the value.
require_valid_password() {
    _name="$1"
    _value="$2"
    if ! validate_password "$_value"; then
        log_error "$_name does not meet the password requirements above"
        exit 1
    fi
}

resolve_dockerhub_credentials() {
    if [ -z "$DOCKERHUB_TOKEN" ]; then
        if [ "$NON_INTERACTIVE" -eq 1 ]; then
            log_error "Docker Hub token is required to pull the Gecko images: pass --dockerhub-token or set DOCKERHUB_TOKEN"
            exit 1
        fi
        while [ -z "$DOCKERHUB_TOKEN" ]; do
            printf "Docker Hub access token for %s: " "$DOCKERHUB_USERNAME"
            stty -echo
            read -r DOCKERHUB_TOKEN
            stty echo
            printf "\n"
        done
    fi
    case "$DOCKERHUB_USERNAME" in
        ''|*[!A-Za-z0-9._-]*)
            log_error "Invalid Docker Hub username"
            exit 1
            ;;
    esac
}

# Print this host's primary IPv4 address (source address of the default route).
# Prints nothing if it cannot be determined.
detect_host_ip() {
    _ip=""
    if command -v ip >/dev/null 2>&1; then
        _ip=$(ip -4 route get 1.1.1.1 2>/dev/null \
            | awk '{for (i = 1; i < NF; i++) if ($i == "src") { print $(i + 1); exit }}')
        if [ -z "$_ip" ]; then
            _ip=$(ip -4 addr show scope global 2>/dev/null \
                | awk '/inet / { sub(/\/.*/, "", $2); print $2; exit }')
        fi
    fi
    if [ -z "$_ip" ] && command -v hostname >/dev/null 2>&1; then
        _ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    fi
    printf '%s' "$_ip"
}

# Kafka advertises KAFKA_EXTERNAL_HOST on its EXTERNAL listener; the infra compose
# files refuse to start without it. Take it from --kafka-external-host, else detect it.
resolve_kafka_external_host() {
    if [ -z "$KAFKA_EXTERNAL_HOST" ]; then
        KAFKA_EXTERNAL_HOST=$(detect_host_ip)
        if [ -n "$KAFKA_EXTERNAL_HOST" ]; then
            log_info "Kafka external host auto-detected: $KAFKA_EXTERNAL_HOST (override with --kafka-external-host)"
        fi
    fi

    if [ -z "$KAFKA_EXTERNAL_HOST" ]; then
        if [ "$NON_INTERACTIVE" -eq 1 ]; then
            log_error "Could not detect this host's IP address; pass --kafka-external-host <IP or DNS name>"
            exit 1
        fi
        while [ -z "$KAFKA_EXTERNAL_HOST" ]; do
            printf "Enter this host's IP address or DNS name (Kafka external listener): "
            read -r KAFKA_EXTERNAL_HOST
        done
    fi

    # Hostname / IPv4 / IPv6 characters only: the value goes into .env and Kafka's
    # advertised listener as-is.
    case "$KAFKA_EXTERNAL_HOST" in
        *[!A-Za-z0-9.:-]*)
            log_error "Invalid --kafka-external-host value: $KAFKA_EXTERNAL_HOST"
            exit 1
            ;;
    esac
}

# ============================================================================
# PHASE 5: Configure Environment
# ============================================================================

configure_environment() {
    log_header "PHASE 5: CONFIGURE ENVIRONMENT"

    # Prompt for SERVICE_PASSWORD
    if [ -z "$SERVICE_PASSWORD" ]; then
        printf "\n"
        printf "${BOLD}Password 1 of 3: SERVICE PASSWORD${NC}\n"
        printf "This password will be used for database authentication:\n"
        printf "  - MongoDB\n"
        printf "  - ClickHouse\n"
        printf "  - Redis\n"
        printf "\n"
        prompt_password "Enter SERVICE_PASSWORD" SERVICE_PASSWORD
    fi

    # Prompt for SHARED_PASSWORD
    if [ -z "$SHARED_PASSWORD" ]; then
        printf "\n"
        printf "${BOLD}Password 2 of 3: SHARED PASSWORD${NC}\n"
        printf "This password will be used for:\n"
        printf "  - All cryptographic operations\n"
        printf "  - Inter-service authentication\n"
        printf "\n"
        prompt_password "Enter SHARED_PASSWORD" SHARED_PASSWORD
    fi

    # Passwords given as options or environment variables get the same checks as prompted ones.
    require_valid_password "SERVICE_PASSWORD" "$SERVICE_PASSWORD"
    require_valid_password "SHARED_PASSWORD" "$SHARED_PASSWORD"
    if [ -n "$VAULT_PASSWORD" ]; then
        require_valid_password "VAULT_PASSWORD" "$VAULT_PASSWORD"
    fi

    resolve_dockerhub_credentials
    resolve_kafka_external_host

    # Create .env file
    log_info "Creating environment configuration..."

    if [ "$DRY_RUN" -eq 0 ]; then
        # Escape backslash, double-quote and $ so values are taken literally inside "..." in
        # .env (compose expands $NAME in double-quoted values: "ab$Xcd" would become "ab").
        # Done via printf so the raw password bytes are never re-interpreted by the shell
        _svc_pw=$(printf '%s' "$SERVICE_PASSWORD" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\$/\\$/g')
        _shared_pw=$(printf '%s' "$SHARED_PASSWORD" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\$/\\$/g')
        _hub_token=$(printf '%s' "$DOCKERHUB_TOKEN" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\$/\\$/g')

        # Write static header with a quoted heredoc (<<'EOF') so no shell expansion occurs
        cat > "$INSTALL_DIR/.env" <<'EOF'
# Gecko Platform Environment Configuration
EOF

        # Append the generated date separately (the only line that needs expansion)
        printf '# Generated on %s\n\n' "$(date)" >> "$INSTALL_DIR/.env"

        # Append passwords via printf — values are already escaped, no heredoc expansion risk
        printf '# Docker Hub credentials (private Gecko images; ManagerApi and Updater use them too)\nDOCKERHUB_USERNAME="%s"\nDOCKERHUB_TOKEN="%s"\n\n' "$DOCKERHUB_USERNAME" "$_hub_token" >> "$INSTALL_DIR/.env"
        printf '# Database and MinIO Authentication\nSERVICE_PASSWORD="%s"\n\n' "$_svc_pw" >> "$INSTALL_DIR/.env"
        printf '# Cryptography and Inter-service Authentication\nSHARED_PASSWORD="%s"\n\n' "$_shared_pw" >> "$INSTALL_DIR/.env"
        printf '# Address Kafka advertises on its EXTERNAL listener (this host)\nKAFKA_EXTERNAL_HOST=%s\n' "$KAFKA_EXTERNAL_HOST" >> "$INSTALL_DIR/.env"
        chmod 600 "$INSTALL_DIR/.env"

        # Verbose: Show .env file contents with masked passwords
        if [ "$VERBOSE" -eq 1 ]; then
            log_verbose ".env file created at $INSTALL_DIR/.env"
            log_verbose ".env file permissions: $(ls -l "$INSTALL_DIR/.env" | awk '{print $1, $3, $4}')"
            log_verbose ".env file contents (secrets masked):"
            sed -E 's/^([A-Z_]*(PASSWORD|TOKEN|SECRET)[A-Z_]*)=.*/\1="***MASKED***"/' "$INSTALL_DIR/.env" | while IFS= read -r line; do
                log_verbose "  $line"
            done
        fi
    fi

    log_success "Environment configuration created"
}

# ============================================================================
# PHASE 6: Docker Login
# ============================================================================

docker_login() {
    log_info "Logging into Docker registry..."

    if [ "$DRY_RUN" -eq 1 ]; then
        log_info "[DRY RUN] Would perform docker login"
        return
    fi

    if ! printf '%s' "$DOCKERHUB_TOKEN" | docker login -u "$DOCKERHUB_USERNAME" --password-stdin; then
        log_error "Docker login failed for $DOCKERHUB_USERNAME (check the Docker Hub token)"
        exit 1
    fi

    log_success "Docker login successful"
}

# ============================================================================
# PHASE 7: Start Infrastructure
# ============================================================================

start_infrastructure() {
    log_header "PHASE 7: START INFRASTRUCTURE"

    if [ "$DRY_RUN" -eq 1 ]; then
        log_info "[DRY RUN] Would start infrastructure services"
        return
    fi

    cd "$INSTALL_DIR"

    # Verify .env file exists and is readable
    if [ ! -f .env ]; then
        log_error ".env file not found in $INSTALL_DIR"
        exit 1
    fi

    log_info "Verifying .env file..."
    if grep -q "SERVICE_PASSWORD=" .env; then
        log_success ".env file is present and contains SERVICE_PASSWORD"
    else
        log_error ".env file is missing SERVICE_PASSWORD"
        exit 1
    fi

    # Test Docker Compose can read environment variables
    log_info "Testing Docker Compose environment variable substitution..."
    if docker compose -f docker-infra-compose.yml config >/dev/null 2>&1; then
        # Check if SERVICE_PASSWORD is being substituted
        if docker compose -f docker-infra-compose.yml config | grep -q "MONGO_INITDB_ROOT_PASSWORD:"; then
            log_success "Docker Compose is reading .env file correctly"

            # Verbose: Show MongoDB environment configuration
            if [ "$VERBOSE" -eq 1 ]; then
                log_verbose "MongoDB environment configuration from Docker Compose:"
                docker compose -f docker-infra-compose.yml config | grep -A5 "mongodb:" | grep -E "MONGO_INITDB|environment:" | while IFS= read -r line; do
                    # Mask password in output
                    masked_line=$(echo "$line" | sed 's/MONGO_INITDB_ROOT_PASSWORD:.*/MONGO_INITDB_ROOT_PASSWORD: ***MASKED***/')
                    log_verbose "  $masked_line"
                done
            fi
        else
            log_warning "Could not verify SERVICE_PASSWORD substitution"
        fi
    else
        log_error "Docker Compose config validation failed:"
        docker compose -f docker-infra-compose.yml config 2>&1 >/dev/null | while IFS= read -r line; do
            log_error "  $line"
        done
        exit 1
    fi

    # Pull images
    log_info "Pulling infrastructure images..."
    if ! docker compose -f docker-infra-compose.yml pull; then
        log_error "Failed to pull infrastructure images"
        exit 1
    fi

    # Start services
    log_info "Starting infrastructure services..."
    log_verbose "Current working directory: $(pwd)"
    log_verbose "Running: docker compose -f docker-infra-compose.yml up -d"

    if ! docker compose -f docker-infra-compose.yml up -d; then
        log_error "Failed to start infrastructure services"
        exit 1
    fi

    # Wait for services to be healthy
    log_info "Waiting for infrastructure services to be healthy (timeout: 5 minutes)..."
    log_verbose "Health check: Testing Kafka connectivity on kafka-1:9092"

    # apache/kafka keeps its CLI in /opt/kafka/bin and does not put it on PATH; the
    # Confluent and Bitnami images do, under two different names. Try each so the probe
    # works whichever image the compose file pins.
    # The bootstrap address is the advertised PLAINTEXT listener (kafka-1:9092). Probing
    # localhost would reach the socket but then get redirected to the advertised EXTERNAL
    # address, which is not routable from inside the container.
    kafka_probe='if command -v kafka-topics.sh >/dev/null 2>&1; then
                     kafka-topics.sh --bootstrap-server kafka-1:9092 --list
                 elif command -v kafka-topics >/dev/null 2>&1; then
                     kafka-topics --bootstrap-server kafka-1:9092 --list
                 else
                     /opt/kafka/bin/kafka-topics.sh --bootstrap-server kafka-1:9092 --list
                 fi'

    timeout=300
    elapsed=0
    interval=5

    while [ $elapsed -lt $timeout ]; do
        # Verbose: Show what we're checking
        if [ "$VERBOSE" -eq 1 ]; then
            log_verbose "Health check attempt $(expr $elapsed / $interval + 1) (${elapsed}s elapsed):"
            log_verbose "  Command: docker compose exec -T kafka-1 sh -c '<kafka-topics> --bootstrap-server kafka-1:9092 --list'"

            # Show container status
            log_verbose "  Container status:"
            docker compose -f docker-infra-compose.yml ps --format "table {{.Service}}\t{{.Status}}" | grep -E "(Service|kafka-1|mongodb|clickhouse|redis)" | while IFS= read -r line; do
                log_verbose "    $line"
            done
        fi

        # Check Kafka
        if docker compose -f docker-infra-compose.yml exec -T kafka-1 sh -c "$kafka_probe" >/dev/null 2>&1; then
            log_success "Kafka is healthy"
            log_verbose "Health check passed after ${elapsed}s"
            break
        fi

        if [ "$VERBOSE" -eq 1 ]; then
            log_verbose "  Result: Kafka not ready yet, waiting ${interval}s..."
        else
            printf "."
        fi

        sleep $interval
        elapsed=$((elapsed + interval))
    done

    if [ "$VERBOSE" -eq 0 ]; then
        printf "\n"
    fi

    if [ $elapsed -ge $timeout ]; then
        log_warning "Health check timeout - services may still be starting"
        log_info "Check logs with: docker compose -f $INSTALL_DIR/docker-infra-compose.yml logs"

        if [ "$VERBOSE" -eq 1 ]; then
            log_verbose "Kafka container logs (last 20 lines):"
            docker compose -f docker-infra-compose.yml logs --tail=20 kafka-1 2>&1 | while IFS= read -r line; do
                log_verbose "  $line"
            done
        fi
    fi

    log_success "Infrastructure services started"
}

# ============================================================================
# PHASE 8: Start Application
# ============================================================================

start_application() {
    log_header "PHASE 8: START APPLICATION"

    if [ "$INFRA_ONLY" -eq 1 ]; then
        log_info "Skipping application services (--infra-only)"
        return
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
        log_info "[DRY RUN] Would start application services"
        return
    fi

    cd "$INSTALL_DIR"

    # Pull images
    log_info "Pulling application images..."
    if ! docker compose -f docker-gecko-compose.yml pull; then
        log_error "Failed to pull application images"
        exit 1
    fi

    # Start services
    log_info "Starting application services..."
    if ! docker compose -f docker-gecko-compose.yml up -d; then
        log_error "Failed to start application services"
        exit 1
    fi

    # Wait for services to be healthy
    log_info "Waiting for application services to be healthy (timeout: 5 minutes)..."
    log_verbose "Health check: Waiting for application containers to start (expecting 10+ services)"

    timeout=300
    elapsed=0
    interval=5

    while [ $elapsed -lt $timeout ]; do
        # Simple check - just wait for containers to be running
        running=$(docker compose -f docker-gecko-compose.yml ps --services --filter "status=running" | wc -l)

        # Verbose: Show what we're checking
        if [ "$VERBOSE" -eq 1 ]; then
            log_verbose "Health check attempt $(expr $elapsed / $interval + 1) (${elapsed}s elapsed):"
            log_verbose "  Running services: ${running}/10+"
            log_verbose "  Container status:"
            docker compose -f docker-gecko-compose.yml ps --format "table {{.Service}}\t{{.Status}}" | head -15 | while IFS= read -r line; do
                log_verbose "    $line"
            done
        fi

        if [ "$running" -gt 10 ]; then
            log_success "Application services are running"
            log_verbose "Health check passed: ${running} services running after ${elapsed}s"
            break
        fi

        if [ "$VERBOSE" -eq 1 ]; then
            log_verbose "  Result: Only ${running} services running, waiting ${interval}s..."
        else
            printf "."
        fi

        sleep $interval
        elapsed=$((elapsed + interval))
    done

    if [ "$VERBOSE" -eq 0 ]; then
        printf "\n"
    fi

    if [ $elapsed -ge $timeout ]; then
        log_warning "Health check timeout - services may still be starting"
        log_info "Check logs with: docker compose -f $INSTALL_DIR/docker-gecko-compose.yml logs"

        if [ "$VERBOSE" -eq 1 ]; then
            log_verbose "Application container status at timeout:"
            docker compose -f docker-gecko-compose.yml ps --format "table {{.Service}}\t{{.Status}}" | while IFS= read -r line; do
                log_verbose "  $line"
            done
        fi
    fi

    log_success "Application services started"
}

# ============================================================================
# PHASE 9: Post-Install
# ============================================================================

create_systemd_service() {
    if [ "$NO_SYSTEMD" -eq 1 ]; then
        log_info "Skipping systemd/OpenRC service creation (Gecko is managed via Docker Compose)"
        return
    fi

    if [ "$OS_ID" = "alpine" ]; then
        log_info "Creating OpenRC service..."

        if [ "$DRY_RUN" -eq 0 ]; then
            cat > /etc/init.d/gecko <<'EOF'
#!/sbin/openrc-run

description="Gecko Platform"
command="/usr/bin/docker"
command_background=false
pidfile="/run/gecko.pid"

depend() {
    need docker
    after docker
}

start() {
    ebegin "Starting Gecko Platform"
    cd /opt/gecko
    docker compose -f docker-infra-compose.yml up -d
    sleep 30
    docker compose -f docker-gecko-compose.yml up -d
    eend $?
}

stop() {
    ebegin "Stopping Gecko Platform"
    cd /opt/gecko
    docker compose -f docker-gecko-compose.yml down
    docker compose -f docker-infra-compose.yml down
    eend $?
}
EOF
            chmod +x /etc/init.d/gecko
            rc-update add gecko default
        fi

        log_success "OpenRC service created and enabled"
    else
        log_info "Creating systemd service..."

        if [ "$DRY_RUN" -eq 0 ]; then
            cat > /etc/systemd/system/gecko.service <<EOF
[Unit]
Description=Gecko Platform
Requires=docker.service
After=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=$INSTALL_DIR
ExecStart=/bin/sh -c 'docker compose -f docker-infra-compose.yml up -d && sleep 30 && docker compose -f docker-gecko-compose.yml up -d'
ExecStop=/bin/sh -c 'docker compose -f docker-gecko-compose.yml down && docker compose -f docker-infra-compose.yml down'
TimeoutStartSec=300

[Install]
WantedBy=multi-user.target
EOF

            systemctl daemon-reload
            systemctl enable gecko.service
        fi

        log_success "Systemd service created and enabled"
    fi
}

encrypt_env_file() {
    if [ "$SKIP_ENCRYPTION" -eq 1 ]; then
        log_warning "Skipping .env encryption (--skip-encryption)"
        log_warning "Your passwords are stored in PLAIN TEXT at: $INSTALL_DIR/.env"
        return
    fi

    if [ "$ANSIBLE_AVAILABLE" -eq 0 ]; then
        log_warning "Ansible is not available - cannot encrypt .env file"
        log_warning "Your passwords are stored in PLAIN TEXT at: $INSTALL_DIR/.env"
        return
    fi

    # Prompt for vault password
    if [ -z "$VAULT_PASSWORD" ]; then
        printf "\n"
        printf "${BOLD}Password 3 of 3: ANSIBLE VAULT PASSWORD${NC}\n"
        printf "This is a master password used to encrypt/decrypt the .env file\n"
        printf "\n"
        printf "${YELLOW}IMPORTANT:${NC}\n"
        printf "  - Keep this password secure and memorable\n"
        printf "  - Password is NEVER stored on disk (you must remember it)\n"
        printf "  - Required for viewing/editing config and uninstalling\n"
        printf "  - Loss of this password means you cannot decrypt your config\n"
        printf "\n"

        if [ "$NON_INTERACTIVE" -eq 1 ]; then
            log_warning "Non-interactive mode: Skipping encryption"
            return
        fi

        prompt_password "Enter VAULT_PASSWORD" VAULT_PASSWORD
    fi

    # Encrypt the .env file
    log_info "Encrypting .env file with ansible-vault..."

    if [ "$DRY_RUN" -eq 0 ]; then
        echo "$VAULT_PASSWORD" | ansible-vault encrypt "$INSTALL_DIR/.env" --vault-password-file=/dev/stdin
        if [ $? -eq 0 ]; then
            log_success ".env file encrypted successfully"
            log_warning "IMPORTANT: Remember your vault password - it's needed to view/edit config and uninstall"
        else
            log_error "Failed to encrypt .env file"
            log_warning "Your passwords are stored in PLAIN TEXT at: $INSTALL_DIR/.env"
        fi
    fi
}

post_install() {
    log_header "PHASE 9: POST-INSTALL"

    # Create systemd service
    create_systemd_service

    # Encrypt .env file
    encrypt_env_file

    # Display summary
    printf "\n"
    log_header "INSTALLATION COMPLETE"
    printf "\n"
    log_success "Gecko Platform has been successfully installed!"
    printf "\n"
    printf "Installation directory: $INSTALL_DIR\n"
    printf "Log file: $LOG_FILE\n"
    printf "\n"
    printf "${BOLD}Access URLs:${NC}\n"
    printf "  Web UI (HTTPS):    https://$(hostname):443\n"
    printf "  API Gateway HTTPS: https://$(hostname):5101\n"

    if [ "$ANSIBLE_AVAILABLE" -eq 1 ] && [ "$SKIP_ENCRYPTION" -eq 0 ]; then
        printf "\n"
        printf "${BOLD}Configuration Management:${NC}\n"
        printf "  View encrypted config:    ansible-vault view $INSTALL_DIR/.env\n"
        printf "  Edit encrypted config:    ansible-vault edit $INSTALL_DIR/.env\n"
        printf "  Note: You will be prompted for your vault password\n"
    fi

    printf "\n"
    printf "${BOLD}Service Management (Docker Compose):${NC}\n"
    printf "  View all services:        cd $INSTALL_DIR && docker compose -f docker-infra-compose.yml ps && docker compose -f docker-gecko-compose.yml ps\n"
    printf "  View logs:                cd $INSTALL_DIR && docker compose -f docker-gecko-compose.yml logs -f\n"
    printf "  Stop services:            cd $INSTALL_DIR && docker compose -f docker-gecko-compose.yml down && docker compose -f docker-infra-compose.yml down\n"
    printf "  Start services:           cd $INSTALL_DIR && docker compose -f docker-infra-compose.yml up -d && sleep 30 && docker compose -f docker-gecko-compose.yml up -d\n"
    printf "  Restart a service:        cd $INSTALL_DIR && docker compose -f docker-gecko-compose.yml restart <service-name>\n"

    printf "\n"
    printf "${YELLOW}Note:${NC} Gecko is fully managed via Docker Compose. Use the commands above to manage services.\n"
    if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != "root" ]; then
        printf "${YELLOW}Note:${NC} If you added your user to the docker group, you may need to\n"
        printf "      logout and login again for the changes to take effect.\n"
    fi
    printf "\n"
}

# ============================================================================
# Uninstall Function
# ============================================================================

uninstall_gecko() {
    log_header "GECKO PLATFORM UNINSTALL"

    log_warning "This will remove the Gecko Platform installation"

    if [ "$NON_INTERACTIVE" -eq 0 ]; then
        if ! prompt_continue "Continue with uninstall"; then
            log_info "Uninstall cancelled"
            exit 0
        fi
    fi

    # Stop and remove containers
    log_info "Stopping and removing containers..."
    if [ -d "$INSTALL_DIR" ]; then
        cd "$INSTALL_DIR" || {
            log_error "Failed to access $INSTALL_DIR"
            exit 1
        }

        log_verbose "Working directory: $(pwd)"

        # Check if .env is encrypted and decrypt it
        if [ -f ".env" ]; then
            if grep -q '$ANSIBLE_VAULT' .env 2>/dev/null; then
                log_info ".env file is encrypted"
                log_info "Please enter vault password to decrypt .env:"

                if ansible-vault decrypt .env; then
                    log_success ".env file decrypted"
                else
                    log_error "Failed to decrypt .env file"
                    log_error "Cannot stop services without decrypted .env"
                    log_info "Correct password is required to match container environment variables"
                    exit 1
                fi
            else
                log_verbose ".env file is not encrypted"
            fi
        else
            log_warning ".env file not found - containers may not stop properly"
        fi

        if [ -f "docker-gecko-compose.yml" ]; then
            log_verbose "Running: docker compose -f docker-gecko-compose.yml down"
            if docker compose -f docker-gecko-compose.yml down; then
                log_success "Application services stopped"
            else
                log_error "Failed to stop application services"
            fi
        fi

        if [ -f "docker-infra-compose.yml" ]; then
            log_verbose "Running: docker compose -f docker-infra-compose.yml down"
            if docker compose -f docker-infra-compose.yml down; then
                log_success "Infrastructure services stopped"
            else
                log_error "Failed to stop infrastructure services"
            fi
        fi
    else
        log_warning "Installation directory $INSTALL_DIR not found"
    fi

    # Remove Docker volumes
    if [ "$NON_INTERACTIVE" -eq 0 ]; then
        if prompt_continue "Remove Docker volumes? (WARNING: This will delete all data)"; then
            log_info "Removing Docker volumes..."
            docker volume ls -q | grep -E 'gecko|mongo|clickhouse|kafka|redis|minio' | xargs -r docker volume rm 2>/dev/null || true
            log_success "Volumes removed"
        fi
    fi

    # Remove installation directory
    if [ "$NON_INTERACTIVE" -eq 0 ]; then
        if prompt_continue "Remove installation directory $INSTALL_DIR"; then
            log_info "Removing installation directory..."
            rm -rf "$INSTALL_DIR"
            log_success "Installation directory removed"
        fi
    else
        log_info "Removing installation directory..."
        rm -rf "$INSTALL_DIR"
        log_success "Installation directory removed"
    fi

    # Remove kernel tuning
    if [ -f /etc/sysctl.d/99-gecko.conf ]; then
        log_info "Removing kernel tuning..."
        rm -f /etc/sysctl.d/99-gecko.conf
        log_success "Kernel tuning removed"
    fi

    log_success "Gecko Platform uninstalled successfully"
    log_info ""
    log_info "To start services again, run the installation script"
}

# ============================================================================
# Self-Download Handler
# ============================================================================

self_download_and_execute() {
    # If we're being piped (no tty), download ourselves and re-execute
    if [ ! -t 0 ]; then
        log_info "Detected piped execution. Downloading script for interactive mode..."

        # mktemp: a predictable /tmp name could be pre-created by another local user
        # and swapped before it is executed as root.
        if ! TEMP_SCRIPT=$(mktemp /tmp/gecko-setup.XXXXXXXXXX); then
            log_error "Failed to create a temporary file"
            exit 1
        fi

        if ! curl -fsSL "${BASE_URL%/}/gecko-setup.sh" -o "$TEMP_SCRIPT"; then
            log_error "Failed to download script from ${BASE_URL%/}/gecko-setup.sh"
            rm -f "$TEMP_SCRIPT"
            exit 1
        fi

        chmod +x "$TEMP_SCRIPT"

        # Mark this as a re-execution so we don't loop
        export GECKO_REEXEC=1

        # Re-execute with all arguments, redirecting stdin from terminal
        exec "$TEMP_SCRIPT" "$@" </dev/tty
    fi
}

cleanup_self() {
    # If we were downloaded to /tmp, clean up
    if [ -n "$GECKO_REEXEC" ] && [ -f "$0" ]; then
        log_info "Cleaning up temporary script..."
        rm -f "$0"
    fi
}

# ============================================================================
# Main Function
# ============================================================================

main() {
    # Check if we need to download ourselves first
    if [ -z "$GECKO_REEXEC" ]; then
        self_download_and_execute "$@"
    fi

    # Parse arguments
    parse_args "$@"

    # Set up logging
    mkdir -p "$INSTALL_DIR/logs" 2>/dev/null || true
    LOG_FILE="$INSTALL_DIR/logs/install-$(date +%Y%m%d-%H%M%S).log"

    # Print banner
    log_info ""
    log_info "╔═══════════════════════════════════════════════════════════╗"
    log_info "║                                                           ║"
    log_info "║           GECKO PLATFORM INSTALLATION SCRIPT              ║"
    log_info "║                     Version $VERSION                         ║"
    log_info "║                                                           ║"
    log_info "╚═══════════════════════════════════════════════════════════╝"
    log_info ""

    if [ "$DRY_RUN" -eq 1 ]; then
        log_warning "DRY RUN MODE - No changes will be made"
        log_info ""
    fi

    # Execute installation phases
    check_prerequisites
    install_dependencies
    configure_kernel
    setup_directories
    configure_environment
    docker_login
    start_infrastructure
    start_application
    post_install

    # Clean up temporary script
    cleanup_self
}

# Run main function
main "$@"