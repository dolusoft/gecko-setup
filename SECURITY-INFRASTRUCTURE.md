# Security Infrastructure Documentation

## Overview

This document describes the security measures implemented for the Gecko Project infrastructure, including port configuration, password protection, and encrypted configuration management.

## Table of Contents

1. [Security Rationale](#security-rationale)
2. [Infrastructure Changes](#infrastructure-changes)
3. [Environment Variable Interpolation](#environment-variable-interpolation)
4. [Ansible Vault Integration](#ansible-vault-integration)
5. [Usage Guide](#usage-guide)
6. [Development vs Production](#development-vs-production)
7. [Best Practices](#best-practices)
8. [Troubleshooting](#troubleshooting)

---

## Security Rationale

### Why We Implemented This Approach

1. **Port Security**: Changed default ports for all infrastructure services to reduce exposure to automated attacks targeting standard ports.

2. **Password Protection**: Added authentication to previously open services:
   - MongoDB (default user with password)
   - Redis (requirepass)
   - ClickHouse (password authentication)
   - All application services now use `SHARED_PASSWORD` and `SERVICE_PASSWORD`

3. **Configuration Encryption**: Sensitive configuration data (passwords, registry URLs) is encrypted at rest using Ansible Vault to prevent:
   - Accidental exposure through version control
   - Unauthorized access on the host system
   - Plain-text secrets in Docker Compose files

4. **Separation of Concerns**: 
   - Infrastructure services isolated in `docker-infra-compose.yml`
   - Application services in `docker-gecko-compose.yml`
   - Secrets managed separately in encrypted `compose.env`

---

## Infrastructure Changes

### Modified Ports

| Service | Original Port | New Port | Access |
|---------|---------------|----------|--------|
| ClickHouse HTTP | 8123 | 8124 | External |
| ClickHouse Native | 9000 | 9001 | External |
| MongoDB | 27017 | 27018 | External |
| Redis | 6379 | 6380 | External |
| Kafka Broker 1 | 9092 | 19092 | External |
| Kafka Broker 2 | 9092 | 29092 | External |
| Kafka Controller | 9093 | 39093 | External |

### Password-Protected Services

All infrastructure services now require authentication:

```yaml
# MongoDB
MONGO_INITDB_ROOT_USERNAME=default
MONGO_INITDB_ROOT_PASSWORD=${SERVICE_PASSWORD}

# Redis
REDIS_ARGS=--requirepass ${SERVICE_PASSWORD}

# ClickHouse
CLICKHOUSE_USER=default
password: ${SERVICE_PASSWORD}

# Application Services
SHARED_PASSWORD=${SHARED_PASSWORD}
SERVICE_PASSWORD=${SERVICE_PASSWORD}
```

---

## Environment Variable Interpolation

### Implementation

Our custom interpolation system allows using environment variables in configuration files using the syntax `${VARIABLE_NAME}`.

```csharp
public static partial class ConfigurationExtensions
{
    public static void InterpolateEnvironmentVariables(this IConfiguration configuration)
    {
        foreach (var section in configuration.GetChildren())
        {
            if (section.Value != null)
            {
                var interpolated = StringMatch().Replace(
                    section.Value, 
                    m => Environment.GetEnvironmentVariable(m.Groups[1].Value) ?? m.Value
                );
                configuration[section.Key] = interpolated;
            }
            else
            {
                section.InterpolateEnvironmentVariables();
            }
        }
    }

    [GeneratedRegex(@"\$\{(\w+)\}")]
    private static partial Regex StringMatch();
}
```

### Usage in appsettings.json

```json
{
  "ConnectionStrings": {
    "Mongo": "mongodb://default:${SERVICE_PASSWORD}@mongodb:27017/?authSource=admin",
    "Redis": "redis:6379,password=${SERVICE_PASSWORD}",
    "Kafka": "kafka-1:19092,kafka-2:29092",
    "OtlpCollector": "http://otel-collector:4317"
  }
}
```

### Integration

The interpolation is called during application startup:

```csharp
services.LoadBuildingBlocks(configuration, callerAssembly);
// ...
configuration.InterpolateEnvironmentVariables();
```

This ensures all connection strings are resolved before services are initialized.

---

## Ansible Vault Integration

### compose.env Structure

The `compose.env` file contains sensitive environment variables:

```bash
# Environment variables for docker-compose
# Local Registry
LOCAL_REGISTRY=172.16.40.15:5000

# Secrets
SHARED_PASSWORD=test
SERVICE_PASSWORD=test
```

### Encryption

Encrypt the compose.env file:

```bash
ansible-vault encrypt compose.env
```

You'll be prompted for a vault password. **Store this password securely** - you'll need it for all future operations.

### The vault-compose.sh Script

This script provides secure, temporary decryption of the environment file:

```bash
#!/bin/sh
set -eu

ENV_FILE="compose.env"
COMPOSE_FILE="docker-gecko-compose.yml"

# secure temp file for decrypted env
TMP_ENV="$(mktemp)"
chmod 600 "$TMP_ENV"

# prompt for password
printf "Vault password: " >&2
stty -echo
IFS= read -r VAULT_PASS
stty echo
printf "\n" >&2

# create FIFO for password (keeps it out of process args and off disk)
PW_FIFO="$(mktemp -u)"
mkfifo "$PW_FIFO"
chmod 600 "$PW_FIFO"

cleanup() {
  rm -f "$TMP_ENV" "$PW_FIFO" 2>/dev/null || true
}
trap cleanup EXIT INT HUP TERM

# feed password into FIFO while ansible-vault runs
( printf "%s" "$VAULT_PASS" > "$PW_FIFO" ) &

# decrypt to temp file
ansible-vault view --vault-password-file "$PW_FIFO" "$ENV_FILE" > "$TMP_ENV"

# run docker-compose
docker-compose --env-file "$TMP_ENV" -f "$COMPOSE_FILE" up -d
```

**Security Features:**
- Password never written to disk or visible in process list
- Uses FIFO (named pipe) for secure password passing
- Temporary files have restricted permissions (600)
- Automatic cleanup on exit, interrupt, or error
- No plaintext secrets left on disk

---

## Usage Guide

### Use Case 1: Running Docker Compose with Encrypted Env

This is the primary use case - starting services with encrypted configuration:

```bash
# Make script executable (first time only)
chmod +x vault-compose.sh

# Run docker-compose with decrypted env
./vault-compose.sh
```

**What happens:**
1. Script prompts for vault password
2. Temporarily decrypts `compose.env` to secure temp file
3. Runs `docker-compose up -d` with decrypted environment
4. Cleans up temporary files immediately
5. Services continue running with loaded environment variables

### Use Case 2: Decrypting for Manual Inspection/Editing

When you need to view or edit the encrypted file:

```bash
# View contents without editing
ansible-vault view compose.env

# Edit contents in-place (encrypted)
ansible-vault edit compose.env

# Decrypt to plaintext file
ansible-vault decrypt compose.env
# ⚠️ WARNING: File is now plaintext! Remember to re-encrypt!

# Re-encrypt after editing
ansible-vault encrypt compose.env
```

**Editing Workflow:**
```bash
# Option 1: Direct editing (recommended)
ansible-vault edit compose.env
# Opens in your $EDITOR, automatically re-encrypts on save

# Option 2: Manual decrypt/encrypt (use with caution)
ansible-vault decrypt compose.env
# Make your changes to compose.env
nano compose.env
# Re-encrypt immediately
ansible-vault encrypt compose.env
```

### Stopping Services

```bash
# Stop all services
docker-compose -f docker-gecko-compose.yml down
docker-compose -f docker-infra-compose.yml down

# Stop with volume removal (data will be lost!)
docker-compose -f docker-gecko-compose.yml down -v
docker-compose -f docker-infra-compose.yml down -v
```

### Viewing Logs

```bash
# View logs for specific service
docker-compose -f docker-gecko-compose.yml logs -f coreapi

# View all infrastructure logs
docker-compose -f docker-infra-compose.yml logs -f
```

---

## Development vs Production

### Development Environment

In development, secrets are set manually in `Program.cs`:

```csharp
if (builder.Environment.IsDevelopment())
{
    Environment.SetEnvironmentVariable(GlobalConstants.CoreApiEnvName, GlobalConstants.CoreApi);
    Environment.SetEnvironmentVariable(GlobalConstants.SharedPasswordEnvName, GlobalConstants.SharedPassword);
    Environment.SetEnvironmentVariable(GlobalConstants.ServicePasswordEnvName, GlobalConstants.ServicePassword);
}
```

**Development workflow:**
1. No Ansible Vault required for local debugging
2. Secrets hardcoded in constants (⚠️ **NEVER commit production secrets**)
3. Direct IDE debugging supported
4. Fast iteration without password prompts

### Production/Staging Environment

In production, always use encrypted configuration:

1. **Never** commit unencrypted `compose.env`
2. Use `vault-compose.sh` for all deployments
3. Store vault password in secure password manager
4. Consider using `--vault-password-file` for CI/CD automation

**CI/CD Integration:**
```bash
# Store vault password as CI secret: $VAULT_PASSWORD
echo "$VAULT_PASSWORD" > /tmp/vault_pass
chmod 600 /tmp/vault_pass

# Deploy using password file
ansible-vault view --vault-password-file /tmp/vault_pass compose.env > /tmp/compose.env
docker-compose --env-file /tmp/compose.env -f docker-gecko-compose.yml up -d

# Clean up
rm -f /tmp/vault_pass /tmp/compose.env
```

---

## Best Practices

### Security

1. **Vault Password Management**
   - Use a strong, unique password (minimum 20 characters)
   - Never share vault password via insecure channels
   - Rotate vault password quarterly

2. **File Permissions**
   ```bash
   chmod 600 compose.env          # Only owner can read/write
   chmod 700 vault-compose.sh     # Only owner can execute
   ```

3. **Git Configuration**
   ```bash
   # Ensure compose.env is in .gitignore
   echo "compose.env" >> .gitignore
   
   # But track the encrypted version
   git add compose.env.vault
   ```

4. **Service Passwords**
   - Use different passwords for `SHARED_PASSWORD` and `SERVICE_PASSWORD`
   - Change default passwords before production deployment
   - Use password generators (minimum 16 characters, mixed case, numbers, symbols)

---

## Troubleshooting

### Common Issues

#### 1. "ERROR! Incorrect vault password"

**Problem:** Wrong password provided to ansible-vault

**Solution:**
```bash
# Verify you have the correct password from password manager
# Try viewing file first
ansible-vault view compose.env

# If password is correct but script fails, check file integrity
file compose.env  # Should show "ASCII text"
```

#### 2. Services Can't Connect to Infrastructure

**Problem:** Infrastructure services not running or ports incorrect

**Solution:**
```bash
# Check infrastructure services are running
docker-compose -f docker-infra-compose.yml ps

# Verify port mappings
docker-compose -f docker-infra-compose.yml ps | grep -E "mongo|redis|clickhouse"

# Check service logs
docker-compose -f docker-infra-compose.yml logs clickhouse
```

#### 3. "Permission denied" on vault-compose.sh

**Problem:** Script not executable

**Solution:**
```bash
chmod +x vault-compose.sh
```

#### 4. Environment Variables Not Interpolated

**Problem:** Connection strings still show `${SERVICE_PASSWORD}` in errors

**Solution:**
```bash
# Verify environment variables are set
docker-compose -f docker-gecko-compose.yml exec coreapi printenv | grep PASSWORD

# Check interpolation is called in BuildingBlocks
# Verify Program.cs sets variables in development
```

#### 5. ClickHouse Authentication Failed

**Problem:** Services can't authenticate to ClickHouse

**Solution:**
```bash
# Test ClickHouse connection
docker exec clickhouse clickhouse-client \
  --host localhost \
  --port 9000 \
  --user default \
  --password "your_service_password"

# Verify password in users.xml
docker exec clickhouse cat /etc/clickhouse-server/users.d/users.xml
```

#### 6. Kafka Brokers Not Reachable

**Problem:** Services can't connect to Kafka

**Solution:**
```bash
# Check Kafka health
docker-compose -f docker-infra-compose.yml exec kafka-1 \
  /opt/kafka/bin/kafka-topics.sh --bootstrap-server kafka-1:9092 --list

# Verify internal network connectivity
docker-compose -f docker-infra-compose.yml exec kafka-1 ping kafka-2

# Check if controller is running
docker-compose -f docker-infra-compose.yml ps kafka-controller
```

### Debugging Commands

```bash
# View decrypted env without starting services
ansible-vault view compose.env

# Test docker-compose config parsing
docker-compose --env-file compose.env -f docker-gecko-compose.yml config

# Check network connectivity between services
docker-compose -f docker-gecko-compose.yml exec coreapi curl http://kafka-1:9092

# Inspect service environment variables
docker-compose -f docker-gecko-compose.yml exec coreapi env | sort

# Check resource usage
docker stats

# View all running containers
docker ps -a

# Inspect specific container
docker inspect clickhouse
```

### Getting Help

If issues persist:

1. Check service-specific logs: `docker-compose logs -f <service_name>`
2. Verify network connectivity: `docker network inspect <network_name>`
3. Review Docker Compose configuration: `docker-compose config`
4. Check system resources: `docker stats` and `df -h`

---

## Security Checklist

Before deploying to production:

- [ ] Changed all default passwords in `compose.env`
- [ ] Encrypted `compose.env` with Ansible Vault
- [ ] Verified `compose.env` is in `.gitignore`
- [ ] Tested vault-compose.sh script execution
- [ ] Documented vault password location in team password manager
- [ ] Configured proper file permissions (600 for env files, 700 for scripts)
- [ ] Updated OpenTelemetry collector with new passwords
- [ ] Verified all services start successfully with encrypted config
- [ ] Tested service-to-service authentication
- [ ] Configured firewall rules for modified ports
- [ ] Set up monitoring for failed authentication attempts
- [ ] Created backup of encrypted configuration

---

## Revision History

| Date | Version | Changes | Author |
|------|---------|---------|--------|
| 2025-11-11 | 1.0 | Initial documentation | Deniz |

---

## Additional Resources

- [Ansible Vault Documentation](https://docs.ansible.com/ansible/latest/vault_guide/index.html)
- [Docker Compose Environment Variables](https://docs.docker.com/compose/environment-variables/)
- [MongoDB Authentication](https://www.mongodb.com/docs/manual/core/authentication/)
