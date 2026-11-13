# Gecko Platform Installation Script

## TL;DR - Quick Start

```bash
# As root (Alpine Linux or any system without sudo)
curl -sSL https://raw.githubusercontent.com/dolusoft/gecko-setup/refs/heads/main/gecko-setup.sh | sh

# With sudo (Ubuntu/Debian/RHEL)
curl -sSL https://raw.githubusercontent.com/dolusoft/gecko-setup/refs/heads/main/gecko-setup.sh | sudo sh
```

The script asks for a Docker Hub access token (the Gecko images are private) and three
passwords. Each password must:
- Be at least 12 characters
- Contain uppercase, lowercase, numbers, and special characters
- Be confirmed by entering twice

Installation takes ~10-15 minutes.

---

## Overview

A curl-installable shell script that deploys the Gecko platform - a high-throughput syslog data processing system with microservices architecture. The script automatically downloads itself for interactive execution, prompts for passwords with validation, installs all dependencies, and configures services.

---

## Target Environment

| Requirement | Specification |
|-------------|---------------|
| **OS** | Ubuntu 22.04+ / Debian 12+ / RHEL 8+ / Alpine Linux 3.18+ |
| **Architecture** | x86_64 (amd64) |
| **RAM** | 16 GB+ recommended |
| **CPU** | 8+ cores recommended |
| **Disk** | 100 GB+ SSD recommended |

**Note:** The script does not enforce resource requirements. Ensure your system meets the recommended specifications for optimal performance.

---

## System Dependencies

| Package | Purpose | Required |
|---------|---------|----------|
| **Docker Engine** | Container runtime for running all Gecko services (v24.0+) | Yes |
| **Docker Compose** | Multi-container orchestration for infrastructure and application stacks (v2.20+ plugin) | Yes |
| **Ansible** | Encrypts the .env file containing sensitive passwords using ansible-vault | Recommended |

**Note:** If Ansible installation fails, the script will continue with an unencrypted .env file and warn the user about security implications.

---

## File Server Setup

The installation server hosts all setup files over plain HTTP on port 80. The server runs nginx on Alpine Linux.

### Initial Setup (one-time)

```bash
apk add nginx

# Write nginx config
cat > /etc/nginx/http.d/setup.conf << 'EOF'
server {
    listen 80;
    root /root/SetupFiles;
    autoindex on;

    location / {
        try_files $uri $uri/ =404;
    }
}
EOF

# Remove default site and allow nginx to read /root
rm /etc/nginx/http.d/default.conf
chmod o+x /root

# Start and enable on boot
rc-service nginx start
rc-update add nginx default
```

Place all files under `/root/SetupFiles/` matching the structure below.

---

## Source Files Structure

All files are hosted on the installation server and downloaded via curl during setup:

```
Hosted files:
├── gecko-setup.sh                     # Main installation script
├── config/
│   ├── users.xml                      # ClickHouse user config
│   ├── log-retention.xml              # ClickHouse log TTL (1 day)
│   ├── otel-collector-config.yml      # OTEL routing config
│   ├── nginx.conf                     # nginx-lb UDP load balancer config (syslog 514)
│   ├── ldap/
│   │   ├── bootstrap.ldif             # OpenLDAP initial OU and test user seed
│   │   └── entrypoint.sh             # Substitutes SHARED_PASSWORD into ldif at startup
│   └── radius/
│       ├── clients.conf               # FreeRADIUS NAS client definitions
│       ├── entrypoint.sh             # Substitutes SHARED_PASSWORD into clients.conf at startup
│       ├── mods-enabled/
│       │   └── rest.conf             # REST module proxying auth to hotspotapi
│       └── sites-enabled/
│           └── default               # Default virtual server (auth/acct on 1812/1813)
├── docker-infra-compose.yml           # Infrastructure services
└── docker-gecko-compose.yml           # Application services
```

---

## Target Installation Structure

```
/opt/gecko/
├── .env                               # Encrypted with ansible-vault (hidden)
├── docker-infra-compose.yml
├── docker-gecko-compose.yml
├── config/
│   ├── users.xml
│   ├── log-retention.xml
│   ├── otel-collector-config.yml
│   ├── nginx.conf
│   ├── ldap/
│   │   ├── bootstrap.ldif
│   │   └── entrypoint.sh
│   └── radius/
│       ├── clients.conf
│       ├── entrypoint.sh
│       ├── mods-enabled/
│       │   └── rest.conf
│       └── sites-enabled/
│           └── default
└── logs/
    └── install.log
```

**Notes:**
- The `.env` file contains passwords and is encrypted with ansible-vault
- Hidden files (starting with `.`) can be viewed with: `ls -la /opt/gecko/`
- You need your vault password to view/edit encrypted config or uninstall
- Docker Compose automatically reads `.env` when starting services (must be decrypted first)

---

## Environment Variables

Prompted during installation:

```bash
# Docker Hub (private dolusoftcomp/* images; ManagerApi and Updater use them too)
DOCKERHUB_USERNAME=dolusoftcomp   # --dockerhub-username, default dolusoftcomp
DOCKERHUB_TOKEN=<prompted>        # --dockerhub-token

# Security (prompted during install)
SERVICE_PASSWORD=<prompted>    # Database and MinIO password (MongoDB, ClickHouse, Redis, MinIO)
SHARED_PASSWORD=<prompted>     # Cryptography and inter-service authentication

# Kafka
KAFKA_EXTERNAL_HOST=<detected> # This host's address; --kafka-external-host overrides
```

All of these can also be given as environment variables of the same name instead of
options, which keeps them out of the process list and shell history.

**Password Prompts (in order):**
1. **SERVICE_PASSWORD**: Used for database authentication (MongoDB, ClickHouse, Redis) and as MinIO's root password
2. **SHARED_PASSWORD**: Used for all cryptographic operations and inter-service authentication. Required: outside Development a backend service whose `SHARED_PASSWORD` is missing or empty stops at startup.
3. **VAULT_PASSWORD** (prompted at end): Master password to encrypt/decrypt the .env file using ansible-vault

**Registry Auth:** All images come from Docker Hub; there is no internal registry. The
script contains no credentials: the Docker Hub token is given at install time
(`--dockerhub-token`, `DOCKERHUB_TOKEN` or the prompt) and written to `.env`.

**Security:** The .env file is encrypted using ansible-vault at the end of installation to protect sensitive passwords at rest. You will need to remember your vault password to view/edit the configuration or uninstall. The vault password is never stored on disk. If Ansible is unavailable, the installation continues with an unencrypted .env file with a security warning.

---

## Deployment Architecture

Infrastructure and application services run as two separate compose stacks sharing a common Docker network.

```
┌─────────────────────────────────────────────────────────────────┐
│                     Docker Network                              │
│                   172.20.0.0/16 (bridge)                        │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  ┌─────────────────────────────────────────────────────────┐    │
│  │            INFRASTRUCTURE (docker-infra-compose)        │    │
│  │                                                         │    │
│  │  kafka-controller ─┬─ kafka-1                           │    │
│  │                    └─ kafka-2                           │    │
│  │                                                         │    │
│  │  clickhouse    mongodb    redis    minio                │    │
│  │                                                         │    │
│  │  otelcollector    chromadb                              │    │
│  └─────────────────────────────────────────────────────────┘    │
│                            │                                    │
│                            ▼                                    │
│  ┌─────────────────────────────────────────────────────────┐    │
│  │            APPLICATION (docker-gecko-compose)           │    │
│  │                                                         │    │
│  │  frontend ── gatewayapi ── coreapi                      │    │
│  │                              │                          │    │
│  │  ┌───────────────────────────┼───────────────────────┐  │    │
│  │  │                           │                       │  │    │
│  │  identityapi  layoutapi  collectorapi  senderapi     │  │    │
│  │  reportapi    alertapi   managerapi    updater       │  │    │
│  │  │                                                   │  │    │
│  │  filtering-engine  alert-notifier                    │  │    │
│  │  │                                                   │  │    │
│  │  listener ── preprocessor ── sinker                  │  │    │
│  │  │                                                   │  │    │
│  │  signexporter    filetransfer    docs                │  │    │
│  └─────────────────────────────────────────────────────────┘    │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

**Startup Order:**
1. `docker-infra-compose.yml` - Infrastructure must be healthy first
2. `docker-gecko-compose.yml` - Application services depend on infrastructure

---

## Infrastructure Layer

| Service | Image | Ports | Resources |
|---------|-------|-------|-----------|
| kafka-controller | apache/kafka:3.9.1 | 39093 | 0.5 CPU, 700M |
| kafka-1 | apache/kafka:3.9.1 | 19092, 19093 | 1.0 CPU, 1G |
| kafka-2 | apache/kafka:3.9.1 | 29092, 29093 | 1.0 CPU, 1G |
| clickhouse | clickhouse:25.1 | 8124, 9001 | 8.0 CPU, 8G |
| mongodb | mongo:7.0.14 | 27018 | 0.6 CPU, 200M |
| redis | redis/redis-stack-server:7.4.0-v5 | 6380 | 0.6 CPU, 500M |
| minio | minio/minio:RELEASE.2025-04-22 | 9002, 9003 | 2.0 CPU, 2G |
| otelcollector | otel/opentelemetry-collector-contrib:0.126.0 | 4317 | 0.3 CPU, 150M |
| chromadb | chromadb/chroma:1.0.9 | 8000 | 0.2 CPU, 50M |

---

## Application Layer

| Service | Purpose | Ports | Resources |
|---------|---------|-------|-----------|
| frontend | Web UI (Nginx/HTTPS) | 443, 24678 | 0.3 CPU, 150M |
| docs | Documentation UI | 3013-3015 | 0.3 CPU, 30M |
| gatewayapi | YARP API Gateway | 5100, 5101 | 0.2 CPU, 80M |
| coreapi | Central Config | internal | 0.2 CPU, 80M |
| identityapi | Authentication | internal | 0.2 CPU, 80M |
| collectorapi | Data Collection | internal | 0.4 CPU, 400M |
| senderapi | Outbound Data | internal | 0.2 CPU, 80M |
| reportapi | Reporting | internal | 0.2 CPU, 80M |
| alertapi | Alert Management | internal | 0.2 CPU, 80M |
| layoutapi | UI Layout | internal | 0.2 CPU, 80M |
| filtering-engine | Real-time Filter | internal | 2.0 CPU, 2G |
| alert-notifier | Notifications | internal | 0.2 CPU, 100M |
| managerapi | System Mgmt | internal | 0.3 CPU, 200M |
| updater | Auto-update | internal | 0.2 CPU, 80M |
| listener | Syslog UDP | 514/udp, 515/udp | 1.0 CPU, 100M |
| preprocessor | Data Preprocessing | internal | 2.0 CPU, 2G |
| sinker | ClickHouse Writer | internal | 2.0 CPU, 4G |
| signexporter | Signature Export | internal | 1.0 CPU, 200M |
| filetransfer | File Transfer | internal | 1.5 CPU, 800M |

---

## Installation Flow

```
┌─────────────────────────────────────────────────────────────────┐
│                    PHASE 1: PREREQUISITES                       │
├─────────────────────────────────────────────────────────────────┤
│  • Verify root/sudo privileges                                  │
│  • Detect OS (Ubuntu/Debian/RHEL/Rocky/Alpine)                  │
│  • Check OS is supported (warn and prompt if unknown)           │
│  • Sync system clock via NTP (required for TLS, Kafka, MongoDB) │
│  • Check for port conflicts                                     │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                 PHASE 2: INSTALL DEPENDENCIES                   │
├─────────────────────────────────────────────────────────────────┤
│  • Update package repositories (3 retries with 5s delay)        │
│    - On failure: Abort installation (critical dependency)       │
│  • Install Docker Engine + Compose plugin (container runtime)   │
│    - Explain: Required for running Gecko services               │
│    - On failure: Abort installation (critical dependency)       │
│  • Configure Docker log rotation (json-file, 10m × 10 files)    │
│    - Writes /etc/docker/daemon.json                             │
│    - Detects existing config and prompts before overwriting     │
│    - Reloads Docker daemon so settings take effect immediately  │
│  • Install Ansible (for encrypting .env)                        │
│    - Explain: Secures passwords in config file                  │
│    - On failure: Warn user, offer to continue without           │
│  • Enable & start Docker service                                │
│  • Add user to docker group                                     │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                 PHASE 3: KERNEL TUNING                          │
├─────────────────────────────────────────────────────────────────┤
│  • vm.max_map_count = 262144 (ClickHouse)                       │
│  • net.core.somaxconn = 65535                                   │
│  • net.ipv4.tcp_max_syn_backlog = 65535                         │
│  • fs.file-max = 2097152                                        │
│  • net.core.rmem_max = 134217728 (syslog UDP)                   │
│  • Apply via sysctl                                             │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│               PHASE 4: SETUP DIRECTORIES & FILES                │
├─────────────────────────────────────────────────────────────────┤
│  • Create /opt/gecko/{config,logs}                              │
│  • Download config files (users.xml, log-retention.xml, etc.)   │
│  • Download compose files from hosting server                   │
│  • Set permissions (755 dirs, 644 files)                        │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│               PHASE 5: CONFIGURE ENVIRONMENT                    │
├─────────────────────────────────────────────────────────────────┤
│  • Get SERVICE_PASSWORD (for MongoDB, ClickHouse, Redis)        │
│  • Get SHARED_PASSWORD (for cryptography & auth)                │
│  • Get Docker Hub token, detect KAFKA_EXTERNAL_HOST             │
│  • Validate password strength (also for options/env variables)  │
│  • Create .env (Docker Hub credentials, passwords, Kafka host)  │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                 PHASE 6: DOCKER LOGIN                           │
├─────────────────────────────────────────────────────────────────┤
│  • Login to Docker Hub with the given token                     │
│  • Required before infra: minio/mc images are private too       │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│              PHASE 7: START INFRASTRUCTURE                      │
├─────────────────────────────────────────────────────────────────┤
│  • Verify .env file exists and contains SERVICE_PASSWORD        │
│  • Test Docker Compose can read environment variables           │
│  • docker compose -f docker-infra-compose.yml pull              │
│  • docker compose -f docker-infra-compose.yml up -d             │
│  • Wait for services (timeout: 5 minutes)                       │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│              PHASE 8: START APPLICATION                         │
├─────────────────────────────────────────────────────────────────┤
│  • docker compose -f docker-gecko-compose.yml pull              │
│  • docker compose -f docker-gecko-compose.yml up -d             │
│  • Wait for health checks:                                      │
│    ├─ coreapi (/healthz)                                        │
│    ├─ identityapi (/healthz)                                    │
│    ├─ alertapi (/healthz)                                       │
│    └─ frontend (HTTPS /nginx_status)                            │
│  • Timeout: 5 minutes                                           │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                  PHASE 9: POST-INSTALL                          │
├─────────────────────────────────────────────────────────────────┤
│  • Prompt 3: VAULT_PASSWORD (for ansible-vault encryption)      │
│    - Explain: Master password to encrypt/decrypt .env           │
│    - Warn: Must remember - needed for config edits & uninstall  │
│    - Security: Password is NEVER stored on disk                 │
│  • Encrypt .env with ansible-vault (if Ansible available)       │
│  • Display summary with Docker Compose management commands      │
│  • Save install log                                             │
│  • Note: No systemd/OpenRC service created (use Docker Compose) │
└─────────────────────────────────────────────────────────────────┘
```

---

## Quick Start

### Installation

Simply run this command:

```bash
# As root (Alpine Linux or any system without sudo)
curl -sSL https://raw.githubusercontent.com/dolusoft/gecko-setup/refs/heads/main/gecko-setup.sh | sh

# With sudo (Ubuntu/Debian/RHEL)
curl -sSL https://raw.githubusercontent.com/dolusoft/gecko-setup/refs/heads/main/gecko-setup.sh | sudo sh
```

The script will:
- Automatically download itself for interactive execution
- Prompt you for three passwords (explained below)
- Install and configure all services
- Clean up after completion

### Passwords You'll Need

The installer will prompt for three passwords:

1. **SERVICE_PASSWORD**: Database authentication (MongoDB, ClickHouse, Redis) and MinIO's root password
2. **SHARED_PASSWORD**: Cryptographic operations and inter-service authentication
3. **VAULT_PASSWORD**: Master password to encrypt/decrypt the configuration file

**Password Requirements:**
- Minimum 12 characters
- At least one uppercase letter (A-Z)
- At least one lowercase letter (a-z)
- At least one number (0-9)
- At least one special character (!@#$%^&*...)
- You will be asked to confirm each password by entering it twice

### Test with Dry Run

To preview what the script will do without making changes:

```bash
curl -sSL https://raw.githubusercontent.com/dolusoft/gecko-setup/refs/heads/main/gecko-setup.sh | sudo sh -s -- --dry-run
```

### What Happens During Installation

The script will:
1. Check prerequisites (root access, OS compatibility, NTP time sync, port availability)
2. Install Docker, configure log rotation, and install Ansible (if not present)
3. Apply kernel tuning for optimal performance
4. Download configuration files from the server
5. Create environment configuration with your passwords
6. Start infrastructure services (Kafka, ClickHouse, MongoDB, Redis, MinIO)
7. Login to Docker Hub for private images
8. Start application services (APIs, frontend, data processors)
9. Encrypt configuration with ansible-vault
10. Display Docker Compose management commands

Total installation time: ~10-15 minutes (depending on download speeds)

**Note:** No systemd/OpenRC service is created. Gecko is managed entirely via Docker Compose.

---

## Command-Line Options

```
Secrets (optional - will prompt if not provided; also read from environment
variables of the same name, e.g. SERVICE_PASSWORD, DOCKERHUB_TOKEN):
  --service-password PW   Database password (MongoDB, ClickHouse, Redis)
  --shared-password PW    Cryptography and inter-service authentication
  --vault-password PW     Ansible vault password (for encrypting .env)
  --dockerhub-username U  Docker Hub user (default: dolusoftcomp)
  --dockerhub-token T     Docker Hub access token (read-only is enough)

Host:
  --kafka-external-host H Address Kafka advertises (default: auto-detected)

Installation Options:
  --install-dir DIR       Installation path (default: /opt/gecko)
  --skip-kernel           Skip sysctl tuning
  --skip-deps             Skip Docker/Ansible install
  --skip-encryption       Skip ansible-vault encryption of .env
  --infra-only            Infrastructure only (no app services)
  --enable-systemd        Create systemd/OpenRC service (not recommended)
  --dry-run               Preview without executing
  --uninstall             Remove installation
  --force                 Force installation (override warnings)
  -v, --verbose           Enable verbose output for debugging
  -h, --help              Show help
```

### Example with Options

```bash
# Non-interactive installation; secrets from the environment so they do not
# appear in the process list or shell history (run as root, or use sudo -E)
export SERVICE_PASSWORD SHARED_PASSWORD VAULT_PASSWORD DOCKERHUB_TOKEN   # set beforehand
curl -sSL https://raw.githubusercontent.com/dolusoft/gecko-setup/refs/heads/main/gecko-setup.sh | sh -s -- -y

# Infrastructure only
curl -sSL https://raw.githubusercontent.com/dolusoft/gecko-setup/refs/heads/main/gecko-setup.sh | sudo sh -s -- --infra-only

# Custom installation directory
curl -sSL https://raw.githubusercontent.com/dolusoft/gecko-setup/refs/heads/main/gecko-setup.sh | sudo sh -s -- --install-dir /opt/custom

# Verbose mode for debugging issues
curl -sSL https://raw.githubusercontent.com/dolusoft/gecko-setup/refs/heads/main/gecko-setup.sh | sudo sh -s -- --verbose
```

**Verbose mode** shows detailed debugging information including:
- .env file contents (passwords and tokens masked)
- Docker Compose configuration validation
- MongoDB container environment variables
- Docker container status and details
- Health check progress with attempt numbers and elapsed time
- Container status for each service during health checks
- Container logs if health checks timeout

Use `-v` or `--verbose` when troubleshooting authentication, configuration, or startup issues.

---

## Firewall Rules Required

```bash
# Essential (must be open)
ufw allow 443/tcp      # Web UI (HTTPS)
ufw allow 514/udp      # Syslog receiver
ufw allow 515/udp      # Syslog receiver (alt)
ufw allow 5100/tcp     # API Gateway (HTTP)
ufw allow 5101/tcp     # API Gateway (HTTPS)

# Optional (admin/debug)
ufw allow 8124/tcp     # ClickHouse HTTP
```

The admin UIs (MinIO console/API 9002/9003, phpLDAPadmin 8080, kafka-ui 9080) listen
on 127.0.0.1 only (`ADMIN_BIND_ADDRESS`). Reach them over an SSH tunnel, e.g.
`ssh -L 9002:127.0.0.1:9002 user@gecko-host`.

---

## Health Check Endpoints

| Service | Check Method | Success |
|---------|--------------|---------|
| coreapi | `wget http://localhost:8080/healthz` | 200 |
| identityapi | `wget http://localhost:8080/healthz` | 200 |
| alertapi | `wget http://localhost:8080/healthz` | 200 |
| frontend | `curl -k https://localhost:443/nginx_status` | 200 |
| clickhouse | `wget http://localhost:8123/ping` | "Ok." |
| kafka-1/2 | `kafka-topics.sh --list` | exit 0 |
| redis | `redis-cli PING` | "PONG" |
| mongodb | `mongosh --eval "db.adminCommand('ping')"` | ok:1 |

---

## Service Management

Gecko is fully managed via Docker Compose. No systemd or OpenRC services are created by default.

**Note:** After a system reboot, you need to manually start services using Docker Compose commands below. Alternatively, use `--enable-systemd` during installation to create an auto-start service.

### View Services

```bash
cd /opt/gecko

# View all services status
docker compose -f docker-infra-compose.yml ps
docker compose -f docker-gecko-compose.yml ps
```

### Start Services

```bash
cd /opt/gecko

# Start infrastructure first
docker compose -f docker-infra-compose.yml up -d

# Wait for infrastructure to be ready
sleep 30

# Start application services
docker compose -f docker-gecko-compose.yml up -d
```

### Stop Services

```bash
cd /opt/gecko

# Stop application services first
docker compose -f docker-gecko-compose.yml down

# Then stop infrastructure
docker compose -f docker-infra-compose.yml down
```

### Restart Services

```bash
cd /opt/gecko

# Restart specific service
docker compose -f docker-gecko-compose.yml restart coreapi

# Restart all application services
docker compose -f docker-gecko-compose.yml restart
```

### View Logs

```bash
cd /opt/gecko

# Follow all application logs
docker compose -f docker-gecko-compose.yml logs -f

# Follow specific service
docker compose -f docker-gecko-compose.yml logs -f coreapi

# Infrastructure logs
docker compose -f docker-infra-compose.yml logs -f mongodb
```

### Update Services

```bash
cd /opt/gecko

# Pull latest images
docker compose -f docker-gecko-compose.yml pull

# Restart with new images
docker compose -f docker-gecko-compose.yml up -d
```

### Upgrading an Install Made Before MinIO Used SERVICE_PASSWORD

MinIO's root password is `SERVICE_PASSWORD`. Older compose files used a separate
`MINIO_ROOT_PASSWORD` (the shared default `test2023!!`, or a random value the setup
script wrote to `.env`). CoreApi saves MinIO's password into its `internal-s3-adapter`
storage adapter only on the first install, so taking the new compose files changes
MinIO's password but not the saved one. Until they match, everything that reads or
writes MinIO through that adapter (exports, hotspot assets) fails to authenticate.

After restarting `minio`, `minio-init` and `coreapi` with the new compose files, edit
the `internal-s3-adapter` storage adapter and set its secret key to the value of
`SERVICE_PASSWORD` in `.env`. The `MINIO_ROOT_PASSWORD` line in `.env`, if there is
one, is no longer read and can be removed.

---

## Error Handling

| Error | Detection | Resolution |
|-------|-----------|------------|
| Docker install fails | Non-zero exit | Explain importance, abort installation (critical) |
| Ansible install fails | Non-zero exit | Explain encryption purpose, warn about unencrypted .env, offer to continue |
| Vault password skipped | User cancels prompt | Warn about security risk, leave .env unencrypted, complete install |
| Port in use | `ss -tulpn` check | List conflicting process, exit |
| Docker pull fails | Non-zero exit | Retry 3x, then fail with instructions |
| Health check timeout | 5 min deadline | Show logs, suggest troubleshooting |
| Ansible encryption fails | Vault command error | Warn user, continue with unencrypted .env file |

**Graceful Degradation:**
- Script explains each dependency's purpose before installation
- Non-critical failures (Ansible) allow continuation with warnings
- Critical failures (Docker) provide clear error messages and exit
- Users are always informed about security implications of failures
- No resource enforcement - administrators are responsible for ensuring adequate resources

---

## Uninstall

```bash
# Works from any directory
curl -sSL https://raw.githubusercontent.com/dolusoft/gecko-setup/refs/heads/main/gecko-setup.sh | sudo sh -s -- --uninstall

# Or if downloaded:
sudo ./gecko-setup.sh --uninstall

# With verbose output to see what's happening:
curl -sSL https://raw.githubusercontent.com/dolusoft/gecko-setup/refs/heads/main/gecko-setup.sh | sudo sh -s -- --uninstall --verbose
```

**Uninstall Process:**
1. Changes to /opt/gecko directory
2. Checks if .env is encrypted:
   - If encrypted: Prompts for vault password to decrypt
   - If decryption fails: Cannot proceed (Docker Compose needs .env to stop containers)
   - If not encrypted: Proceeds directly
3. Stops all application containers (docker-gecko-compose.yml)
4. Stops all infrastructure containers (docker-infra-compose.yml)
5. Prompt: Remove Docker volumes? (data loss warning)
6. Prompt: Remove /opt/gecko directory?
7. Removes kernel tuning configuration

**Notes:**
- The uninstall works from any directory - it automatically changes to the installation directory before stopping services
- If .env is encrypted, you MUST enter the correct vault password to decrypt it
- Without decrypting .env, containers cannot be stopped properly (environment variables won't match)

---

## Working with Encrypted Configuration

The .env file is encrypted with ansible-vault after installation. You need your vault password to view or edit it.

```bash
cd /opt/gecko

# View encrypted file (prompts for vault password)
ansible-vault view .env

# Edit encrypted file (prompts for vault password)
ansible-vault edit .env

# Manually decrypt/encrypt
ansible-vault decrypt .env  # Prompts for password
# ... make changes to decrypted .env ...
ansible-vault encrypt .env  # Prompts for password

# Change vault password
ansible-vault rekey .env  # Prompts for old and new passwords
```

**Important:**
- Keep your vault password secure and memorable - it's never stored on disk
- Docker Compose reads `.env` automatically when in /opt/gecko directory
- If `.env` is encrypted, you must decrypt it before starting services:
  ```bash
  cd /opt/gecko
  ansible-vault decrypt .env  # Enter vault password
  docker compose -f docker-infra-compose.yml up -d
  # Optionally re-encrypt after starting:
  ansible-vault encrypt .env  # Enter vault password
  ```
- **Security best practice:** Keep .env encrypted when services are not running

---

## Troubleshooting

### Can't see .env file

The .env file is hidden (starts with a dot). Use `ls -la /opt/gecko/` to view it.

### Password validation failing

Ensure your password meets all requirements:
- Minimum 12 characters
- At least one uppercase letter (A-Z)
- At least one lowercase letter (a-z)
- At least one number (0-9)
- At least one special character (e.g., !@#$%^&*)

### Services not starting

Check service status:
```bash
cd /opt/gecko

# Check Docker containers
docker ps

# View service status
docker compose -f docker-infra-compose.yml ps
docker compose -f docker-gecko-compose.yml ps
```

View logs:
```bash
# Infrastructure logs
docker compose -f /opt/gecko/docker-infra-compose.yml logs -f

# Application logs
docker compose -f /opt/gecko/docker-gecko-compose.yml logs -f

# Installation log
cat /opt/gecko/logs/install-*.log
```

### Port conflicts

If ports are already in use, stop conflicting services:
```bash
# Check what's using a port
ss -tulpn | grep :443
netstat -tulpn | grep :443

# Stop the conflicting service
systemctl stop <service-name>
```

### Docker permission denied

If you see "permission denied" errors with Docker:
```bash
# Add your user to docker group (already done by installer)
sudo usermod -aG docker $USER

# Logout and login again for changes to take effect
exit
```

### Repository update failures

If you see errors updating package repositories:
```
WARNING: updating http://alpine.adiscon.com/3.7/stable: temporary error (try again later)
[WARN] Repository update failed (attempt 1/3)
```

The script automatically retries 3 times with 5-second delays. If all retries fail:

1. **Check internet connection:**
   ```bash
   ping -c 3 google.com
   ```

2. **Check DNS resolution:**
   ```bash
   nslookup alpine.adiscon.com
   ```

3. **Try different mirror (Alpine):**
   ```bash
   # Edit /etc/apk/repositories and change mirror
   vi /etc/apk/repositories
   ```

4. **Clear package cache:**
   ```bash
   # Alpine
   rm -rf /var/cache/apk/*

   # Ubuntu/Debian
   apt-get clean

   # RHEL/Rocky
   yum clean all
   ```

### Installation failed mid-way

To retry installation:
```bash
# Clean up partial installation
curl -sSL https://raw.githubusercontent.com/dolusoft/gecko-setup/refs/heads/main/gecko-setup.sh | sudo sh -s -- --uninstall

# Run installation again
curl -sSL https://raw.githubusercontent.com/dolusoft/gecko-setup/refs/heads/main/gecko-setup.sh | sudo sh
```

### MongoDB authentication error

If you see MongoDB authentication errors like:
```
MongoDB.Driver.MongoConfigurationException: The connection string 'mongodb://<hidden>@mongodb:27017/?authSource=admin' is not valid.
```

This usually means Docker Compose isn't reading the `.env` file properly.

**First, run the installation with verbose mode to see detailed diagnostics:**
```bash
curl -sSL https://raw.githubusercontent.com/dolusoft/gecko-setup/refs/heads/main/gecko-setup.sh | sudo sh -s -- --verbose
```

If already installed, manually verify the following:

```bash
cd /opt/gecko

# 1. Check .env file exists
ls -la .env

# 2. Verify .env contains SERVICE_PASSWORD
grep SERVICE_PASSWORD .env

# 3. Check if .env is encrypted (should show plain text during first install)
head -1 .env

# 4. Test Docker Compose can read environment variables
docker compose -f docker-infra-compose.yml config | grep MONGO_INITDB_ROOT_PASSWORD

# 5. If the password is showing as empty or missing, manually check:
cat .env
```

If the `.env` file is encrypted (shows `$ANSIBLE_VAULT`), decrypt it:
```bash
cd /opt/gecko
ansible-vault decrypt .env  # Enter your vault password when prompted
```

Make sure you're running Docker Compose from `/opt/gecko` directory where the `.env` file is located.

### Need help

Check the installation log:
```bash
tail -100 /opt/gecko/logs/install-*.log
```

For support, include:
- Operating system and version
- Error messages from logs
- Output of `docker --version` and `docker compose version`