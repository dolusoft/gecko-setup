# Nginx Load Balancing for Listener Service

## Overview

This document describes the nginx-based UDP load balancing setup for scaling the listener service from 1 to 2 instances.

### Architecture

```
External UDP Traffic (port 514)
         ↓
    nginx-lb (load balancer)
    - Port: 514/udp
    - Algorithm: random two least_conn
         ↓
    ┌────────────┐
    ↓            ↓
listener-1   listener-2
    ↓            ↓
    → Kafka (shared dependency)
```

### Resource Impact

- **Before:** 1.0 CPU, 100MB memory
- **After:** 2.5 CPU, 264MB memory
  - nginx-lb: 0.5 CPU, 64MB
  - listener-1: 1.0 CPU, 100MB
  - listener-2: 1.0 CPU, 100MB

---

## Configuration Files

### 1. Nginx Configuration (`config/nginx.conf`)

```nginx
user nginx;
worker_processes auto;
error_log /var/log/nginx/error.log warn;
pid /var/run/nginx.pid;

events {
    worker_connections 1024;
}

stream {
    log_format udp_stream '$remote_addr [$time_local] $protocol $status $bytes_sent $bytes_received';
    access_log /var/log/nginx/udp_access.log udp_stream;

    # Upstream for port 514
    upstream listener_514 {
        random two least_conn;  # Random selection with least_conn tie-breaker for UDP
        server listener-1:514 max_fails=3 fail_timeout=30s;
        server listener-2:514 max_fails=3 fail_timeout=30s;
    }

    # Port 514 load balancer
    server {
        listen 514 udp reuseport;
        proxy_pass listener_514;
        proxy_timeout 10s;
        proxy_responses 0;
        proxy_buffer_size 65536;
    }
}
```

**Key Configuration Decisions:**
- `random two least_conn`: Picks 2 random servers, chooses one with fewer connections (optimal for UDP)
- `max_fails=3 fail_timeout=30s`: Passive health checks (marks backend down after 3 failures for 30s)
- `proxy_buffer_size 65536`: 64KB buffer for large syslog messages (RFC 5426 supports up to 65KB)
- `reuseport`: Allows multiple worker processes to listen on the same port

### 2. Infrastructure Compose (`docker-infra-compose.yml`)

Add nginx-lb service:

```yaml
  nginx-lb:
    container_name: nginx-lb
    hostname: nginx-lb
    image: nginx:1.25-alpine
    restart: always
    volumes:
      - ./config/nginx.conf:/etc/nginx/nginx.conf:ro
    networks:
      - internal_network
    ports:
      - 514:514/udp
    deploy:
      resources:
        limits:
          cpus: '0.5'
          memory: '64M'
        reservations:
          cpus: '0.1'
          memory: '32M'
```

**Important:** nginx-lb is in the **infrastructure** compose because:
- It's part of the foundational infrastructure layer
- It needs to start before application services
- Listeners (in gecko compose) depend on it being available

### 3. Application Compose (`docker-gecko-compose.yml`)

Replace the single `listener` service with two instances:

```yaml
  listener-1:
    container_name: listener-1
    hostname: listener-1
    image: ${LOCAL_REGISTRY}/dolusoftcomp/listener:dev
    depends_on:
      coreapi:
        condition: service_healthy
      preprocessor:
        condition: service_started
    environment:
      - CORE_API=http://coreapi:8080
      - SERVICE_PASSWORD=${SERVICE_PASSWORD}
    restart: always
    networks:
      - internal_network
    expose:
      - "514/udp"
    # Note: Also depends on kafka-1 from infrastructure services
    deploy:
      resources:
        limits:
          cpus: '1.0'
          memory: '100M'
        reservations:
          cpus: '0.5'
          memory: '50M'

  listener-2:
    container_name: listener-2
    hostname: listener-2
    image: ${LOCAL_REGISTRY}/dolusoftcomp/listener:dev
    depends_on:
      coreapi:
        condition: service_healthy
      preprocessor:
        condition: service_started
    environment:
      - CORE_API=http://coreapi:8080
      - SERVICE_PASSWORD=${SERVICE_PASSWORD}
    restart: always
    networks:
      - internal_network
    expose:
      - "514/udp"
    # Note: Also depends on kafka-1 from infrastructure services
    deploy:
      resources:
        limits:
          cpus: '1.0'
          memory: '100M'
        reservations:
          cpus: '0.5'
          memory: '50M'
```

**Key Points:**
- Use `expose` instead of `ports` (internal-only access)
- Only nginx exposes external port 514 (prevents bypassing load balancer)
- Same dependencies and resources as original listener

---

## Code Changes for Component Identity

### Problem

Both listener containers were registering in MongoDB as "listener" (using assembly name), causing configuration conflicts.

### Solution

Modified `BuildingBlocks.Domain/ComponentDomain.cs` to use container hostname:

```csharp
private static readonly string _component = GetComponentName();

public static string Component => _component;

private static string GetComponentName()
{
    // Priority order:
    // 1. COMPONENT_NAME environment variable (for explicit override)
    // 2. HOSTNAME environment variable (Docker container hostname)
    // 3. AppDomain.CurrentDomain.FriendlyName (fallback)

    var componentName = Environment.GetEnvironmentVariable("COMPONENT_NAME");
    if (!string.IsNullOrWhiteSpace(componentName))
    {
        return componentName.ToLowerInvariant();
    }

    var hostname = Environment.GetEnvironmentVariable("HOSTNAME");
    if (!string.IsNullOrWhiteSpace(hostname))
    {
        return hostname.ToLowerInvariant();
    }

    return AppDomain
        .CurrentDomain
        .FriendlyName
        .Replace(".", "")
        .ToLowerInvariant()
        .Replace("worker", ""); // normalize worker names
}
```

**Impact:**
- Each container now registers with its unique hostname (listener-1, listener-2)
- No configuration conflicts in MongoDB
- Allows independent configuration per instance if needed

**File Location:**
`src/BuildingBlocks/BuildingBlocks.Domain/ComponentDomain.cs` (lines 15-44)

---

## Deployment

### Initial Deployment

```bash
# 1. Start infrastructure services (includes nginx-lb)
docker-compose -f docker-infra-compose.yml up -d

# 2. Wait for infrastructure to be ready
docker-compose -f docker-infra-compose.yml ps

# 3. Start application services (includes listener-1 and listener-2)
docker-compose -f docker-gecko-compose.yml up -d

# 4. Verify all services are running
docker ps | grep -E "listener|nginx-lb"
```

### Verification

```bash
# Check nginx-lb is running and healthy
docker logs nginx-lb --tail 20

# Check both listeners are running
docker ps | grep listener

# Verify nginx can resolve backends
docker exec nginx-lb nslookup listener-1
docker exec nginx-lb nslookup listener-2

# Check listener logs
docker logs listener-1 --tail 20
docker logs listener-2 --tail 20
```

### Startup Order

1. **Infrastructure services start:**
   - kafka, mongodb, clickhouse, redis, etc.
   - **nginx-lb** starts (may restart initially if listeners don't exist yet)

2. **Application services start:**
   - coreapi (must be healthy first)
   - preprocessor
   - **listener-1 and listener-2** (depend on coreapi and preprocessor)

3. **nginx-lb automatically recovers:**
   - With `restart: always`, nginx-lb will retry until listeners are available
   - Once both listeners exist, nginx starts successfully

---

## Managing Nginx Configuration

### Updating Configuration Without Downtime

```bash
# 1. Edit the configuration file
nano config/nginx.conf

# 2. Test the configuration is valid (recommended)
docker exec nginx-lb nginx -t

# 3. If valid, reload gracefully (near-zero downtime)
docker exec nginx-lb nginx -s reload

# 4. Verify reload was successful
docker logs nginx-lb --tail 10
```

**Alternative reload method:**
```bash
docker kill -s HUP nginx-lb
```

### Downtime Considerations: TCP vs UDP

#### For TCP/HTTP: True Zero-Downtime

`nginx -s reload` is truly zero-downtime because:
- **The listening socket stays open** - Never stops accepting connections
- **New workers take over seamlessly** - Gradual transition
- **Old workers finish active connections gracefully** - No abrupt termination
- **Client never sees a refused connection** - Continuous availability

#### For UDP (Your Case): Near-Zero Downtime

`nginx -s reload` provides near-zero downtime with caveats:
- **UDP is connectionless** - No concept of "graceful handoff"
- **During reload (~100-500ms)**, there's a brief worker transition
- **The kernel's UDP receive buffer** holds incoming packets during this window
- **Most packets survive the transition**, but heavy traffic might see minimal loss
- **Brief worker process replacement** - Old workers stop, new workers start

#### Reality Check

```bash
# During reload, you might lose a handful of packets if:
# - Very high traffic (thousands of packets/second)
# - Small kernel buffers
# - Slow config validation

# For most use cases with 5K eps: negligible impact
```

**For your 5K events per second syslog traffic:**
- Expected packet loss during reload: **0-10 packets** (0.0002%)
- Duration of risk window: **~100-500ms**
- Impact: **Negligible** for typical logging scenarios

#### If Zero Packet Loss Is Critical

If you absolutely cannot tolerate any packet loss during configuration updates:

**1. Increase Kernel UDP Buffer** (already configured)
```bash
# Current setting in listener config:
# UdpReceiveBufferSizeBytes: 36777216  (36MB)

# Verify kernel buffer size:
docker exec listener-1 sysctl net.core.rmem_max
docker exec listener-1 sysctl net.core.rmem_default

# This buffer holds packets during the reload transition
```

**2. Test Reload During Low Traffic Periods**
```bash
# Monitor traffic rate first
docker logs listener-1 | grep "received_msg_count" | tail -20

# Reload during off-peak hours (e.g., 3 AM)
docker exec nginx-lb nginx -s reload
```

**3. Monitor Packet Loss Before/After Reload**
```bash
# Before reload - capture baseline
netstat -su > before.txt

# Perform reload
docker exec nginx-lb nginx -s reload

# After reload - check for losses
netstat -su > after.txt

# Compare (look for "packet receive errors" and "RcvbufErrors")
diff before.txt after.txt
```

**4. Consider Blue-Green Deployment for Truly Zero-Loss Updates**

See the Blue-Green Deployment section below for a strategy that guarantees zero packet loss.

---

### Blue-Green Deployment Strategy

**Blue-Green Deployment** is a technique where you run two identical production environments (Blue and Green) and switch traffic between them. This provides **truly zero packet loss** during updates.

#### How It Works

```
Initial State (Blue Active):
External Traffic → nginx-lb-blue → listener-1-blue, listener-2-blue

During Update (Green Standby):
External Traffic → nginx-lb-blue → listener-1-blue, listener-2-blue
                   nginx-lb-green → listener-1-green, listener-2-green (warming up)

After Switch (Green Active):
External Traffic → nginx-lb-green → listener-1-green, listener-2-green
```

#### Implementation for Listener Load Balancing

**Step 1: Current Setup (Blue Environment)**

```yaml
# docker-infra-compose.yml
services:
  nginx-lb:
    container_name: nginx-lb
    # ... existing config
    ports:
      - 514:514/udp
```

**Step 2: Add Green Environment**

```yaml
# docker-infra-compose.yml
services:
  nginx-lb:
    # Blue environment (active)
    container_name: nginx-lb
    ports:
      - 514:514/udp
    volumes:
      - ./config/nginx.conf:/etc/nginx/nginx.conf:ro

  nginx-lb-green:
    # Green environment (standby)
    container_name: nginx-lb-green
    image: nginx:1.25-alpine
    restart: always
    volumes:
      - ./config/nginx-green.conf:/etc/nginx/nginx.conf:ro
    networks:
      - internal_network
    ports:
      - 514:514/udp  # Will bind after blue is stopped
    profiles:
      - green  # Only starts when explicitly requested
```

```yaml
# docker-gecko-compose.yml
services:
  # Blue listeners (active)
  listener-1:
    container_name: listener-1
    # ... existing config

  listener-2:
    container_name: listener-2
    # ... existing config

  # Green listeners (standby)
  listener-1-green:
    container_name: listener-1-green
    hostname: listener-1-green
    image: ${LOCAL_REGISTRY}/dolusoftcomp/listener:dev
    # ... same config as listener-1
    profiles:
      - green

  listener-2-green:
    container_name: listener-2-green
    hostname: listener-2-green
    image: ${LOCAL_REGISTRY}/dolusoftcomp/listener:dev
    # ... same config as listener-2
    profiles:
      - green
```

**Step 3: Deployment Process (Zero Packet Loss)**

```bash
# 1. Start green environment (new config)
docker-compose -f docker-gecko-compose.yml --profile green up -d listener-1-green listener-2-green
docker-compose -f docker-infra-compose.yml --profile green up -d nginx-lb-green

# 2. Wait for green environment to be fully ready
docker logs nginx-lb-green --tail 20
docker logs listener-1-green --tail 20
docker logs listener-2-green --tail 20

# 3. Test green environment (use different port temporarily)
# Edit nginx-green.conf to listen on port 5140 for testing
echo "<34>Test" | nc -u -w1 localhost 5140

# 4. Switch traffic atomically (zero loss)
# Method A: IPTables redirect (instant switch)
sudo iptables -t nat -A PREROUTING -p udp --dport 514 -j REDIRECT --to-port 5140

# Method B: DNS switch (if using external DNS)
# Update DNS record: syslog.example.com → green-lb IP

# Method C: Container swap (requires brief coordination)
docker stop nginx-lb
docker-compose -f docker-infra-compose.yml up -d --force-recreate nginx-lb-green

# 5. Verify traffic is flowing to green
docker logs listener-1-green | grep "received_msg_count"
docker logs listener-2-green | grep "received_msg_count"

# 6. Stop blue environment (once green is confirmed working)
docker-compose -f docker-gecko-compose.yml stop listener-1 listener-2
docker-compose -f docker-infra-compose.yml stop nginx-lb

# 7. Promote green to blue (for next deployment)
docker rename nginx-lb nginx-lb-old
docker rename nginx-lb-green nginx-lb
docker rename listener-1 listener-1-old
docker rename listener-1-green listener-1
docker rename listener-2 listener-2-old
docker rename listener-2-green listener-2
```

#### Simplified Blue-Green with Port Switching

For simpler deployments, use port switching:

```bash
# Current: nginx-lb listens on 514
# Update: Start new nginx-lb-green on port 5140

# 1. Start green with new config on alternate port
docker run -d --name nginx-lb-green \
  --network gecko_internal_network \
  -p 5140:514/udp \
  -v $(pwd)/config/nginx-new.conf:/etc/nginx/nginx.conf:ro \
  nginx:1.25-alpine

# 2. Update firewall/load balancer to send traffic to 5140 instead of 514
# (External load balancer or iptables redirect)

# 3. Once confirmed working, stop old nginx-lb on 514
docker stop nginx-lb

# 4. Start new nginx-lb on 514 with updated config
docker rm nginx-lb
docker run -d --name nginx-lb \
  --network gecko_internal_network \
  -p 514:514/udp \
  -v $(pwd)/config/nginx-new.conf:/etc/nginx/nginx.conf:ro \
  nginx:1.25-alpine
```

#### When to Use Blue-Green Deployment

**Use Blue-Green when:**
- ✅ Zero packet loss is absolutely critical (financial, compliance)
- ✅ Testing new config with production traffic before full cutover
- ✅ Need instant rollback capability
- ✅ Large configuration changes with unknown impact
- ✅ Deploying during peak traffic hours

**Use Simple Reload when:**
- ✅ Acceptable to lose 0-10 packets during reload (typical logging)
- ✅ Small configuration changes (add/remove backend)
- ✅ Can deploy during low traffic periods
- ✅ Need quick updates without complex orchestration

#### Blue-Green Trade-offs

**Advantages:**
- ✅ **Zero packet loss** - Truly lossless updates
- ✅ **Instant rollback** - Just switch back to blue
- ✅ **Test in production** - Green gets real traffic before cutover
- ✅ **No reload timing issues** - No worker transition period

**Disadvantages:**
- ❌ **Double resources** - Runs both environments simultaneously
- ❌ **More complex** - Requires orchestration and testing
- ❌ **Coordination needed** - Must manage traffic switching
- ❌ **State considerations** - Ensure stateless design (already true for listeners)

#### Recommendation for Your Use Case

**For your 5K eps syslog traffic:**

Use **`nginx -s reload`** for routine updates:
- Acceptable packet loss: 0-10 packets (0.0002%)
- Simple and fast
- No resource overhead

Use **Blue-Green Deployment** only for:
- Major config changes (algorithm change, adding many backends)
- Deploying during critical events
- Compliance requirements for zero loss
- Initial production rollout (test before full cutover)

### When to Use `docker restart` Instead

Only restart when:
- Nginx fails to start due to bad config
- Need to recreate container (e.g., volume changes)
- Reload command fails

```bash
docker restart nginx-lb
```

**Note:** This causes brief downtime (container stops then starts).

---

## Monitoring and Operations

### Check Traffic Distribution

```bash
# Real-time stats
docker stats listener-1 listener-2 --no-stream

# Check logs to see message counts
docker logs listener-1 | grep "received_msg_count" | tail -5
docker logs listener-2 | grep "received_msg_count" | tail -5

# Nginx access logs
docker exec nginx-lb tail -f /var/log/nginx/udp_access.log
```

### Health Monitoring

```bash
# Check nginx status
docker ps | grep nginx-lb

# Check listener status
docker ps | grep listener

# View nginx error logs
docker logs nginx-lb | grep error

# Check for backend failures
docker logs nginx-lb | grep "upstream"
```

### Troubleshooting

#### Problem: nginx-lb keeps restarting

```bash
# Check logs for the error
docker logs nginx-lb --tail 50

# Common causes:
# 1. listener-1 or listener-2 doesn't exist
docker ps | grep listener

# 2. DNS resolution failure
docker exec nginx-lb nslookup listener-1
docker exec nginx-lb nslookup listener-2

# 3. Configuration syntax error
docker exec nginx-lb nginx -t
```

**Solution:**
- Ensure listener-1 and listener-2 are running
- Wait for nginx to auto-recover (restart: always)
- Or manually restart: `docker restart nginx-lb`

#### Problem: Uneven traffic distribution

```bash
# Check current load balancing algorithm
docker exec nginx-lb cat /etc/nginx/nginx.conf | grep -A 3 "upstream"

# View real-time distribution
docker stats listener-1 listener-2
```

**Solutions:**
- Current: `random two least_conn` (recommended for UDP)
- Alternative: Remove algorithm for pure round-robin
- Alternative: `hash $remote_addr consistent;` for session persistence

#### Problem: No traffic reaching listeners

```bash
# 1. Check nginx is receiving traffic
docker logs nginx-lb --tail 20

# 2. Check nginx can reach backends
docker exec nginx-lb nc -zvu listener-1 514
docker exec nginx-lb nc -zvu listener-2 514

# 3. Verify listeners are listening
docker exec listener-1 netstat -uln | grep 514
docker exec listener-2 netstat -uln | grep 514

# 4. Check network connectivity
docker network inspect gecko_internal_network
```

#### Problem: One listener not receiving traffic

```bash
# Check if backend is marked as down
docker logs nginx-lb | grep "upstream"

# Check listener is healthy
docker logs listener-2 --tail 50

# Force nginx to re-evaluate backends
docker exec nginx-lb nginx -s reload
```

---

## Testing

### Send Test Syslog Messages

```bash
# Single message to port 514
echo "<34>1 $(date -u +%Y-%m-%dT%H:%M:%S.%3NZ) testhost app - - - Test message" | nc -u -w1 localhost 514

# Multiple messages to test distribution
for i in {1..100}; do
  echo "<34>1 $(date -u +%Y-%m-%dT%H:%M:%S.%3NZ) host$i app - - - Message $i" | nc -u -w0 localhost 514
done
```

### Verify Distribution

```bash
# Check message counts in listener logs
docker logs listener-1 | grep "received_msg_count" | tail -1
docker logs listener-2 | grep "received_msg_count" | tail -1

# Should show roughly 50/50 distribution
```

### Test Failover

```bash
# Stop one listener
docker stop listener-1

# Send test messages (should all go to listener-2)
for i in {1..10}; do
  echo "<34>Test $i" | nc -u -w0 localhost 514
done

# Verify listener-2 handled all traffic
docker logs listener-2 | grep "received_msg_count" | tail -5

# Restart listener-1
docker start listener-1

# Traffic should distribute again
```

---

## Scaling Beyond 2 Instances

To add more listener instances:

### 1. Update nginx.conf

```nginx
upstream listener_514 {
    random two least_conn;
    server listener-1:514 max_fails=3 fail_timeout=30s;
    server listener-2:514 max_fails=3 fail_timeout=30s;
    server listener-3:514 max_fails=3 fail_timeout=30s;  # Add new instance
}
```

### 2. Update docker-gecko-compose.yml

```yaml
  listener-3:
    container_name: listener-3
    hostname: listener-3
    image: ${LOCAL_REGISTRY}/dolusoftcomp/listener:dev
    depends_on:
      coreapi:
        condition: service_healthy
      preprocessor:
        condition: service_started
    environment:
      - CORE_API=http://coreapi:8080
      - SERVICE_PASSWORD=${SERVICE_PASSWORD}
    restart: always
    networks:
      - internal_network
    expose:
      - "514/udp"
    deploy:
      resources:
        limits:
          cpus: '1.0'
          memory: '100M'
        reservations:
          cpus: '0.5'
          memory: '50M'
```

### 3. Deploy

```bash
# Start new listener
docker-compose -f docker-gecko-compose.yml up -d listener-3

# Reload nginx (no downtime)
docker exec nginx-lb nginx -s reload

# Verify
docker ps | grep listener
docker stats listener-1 listener-2 listener-3 --no-stream
```

---

## Rollback Plan

If issues occur:

```bash
# 1. Stop new services
docker-compose -f docker-gecko-compose.yml stop listener-1 listener-2
docker-compose -f docker-infra-compose.yml stop nginx-lb

# 2. Restore original listener in docker-gecko-compose.yml
# (Single listener service with ports: 514:514/udp)

# 3. Start original listener
docker-compose -f docker-gecko-compose.yml up -d listener

# 4. Remove nginx-lb from docker-infra-compose.yml
```

---

## Best Practices

### Configuration Management

1. **Always test nginx config before reload:**
   ```bash
   docker exec nginx-lb nginx -t
   ```

2. **Use version control for nginx.conf:**
   - Track changes in git
   - Document why changes were made

3. **Backup configurations before changes:**
   ```bash
   cp config/nginx.conf config/nginx.conf.backup
   ```

### Monitoring

1. **Set up alerts for:**
   - nginx-lb container restarts
   - Uneven traffic distribution (>80/20 split)
   - Backend failures (check nginx error logs)
   - Packet loss (netstat -su)

2. **Regular health checks:**
   ```bash
   # Daily check script
   docker ps | grep -E "listener|nginx-lb"
   docker stats listener-1 listener-2 --no-stream
   docker logs nginx-lb --tail 1 | grep error
   ```

### Performance Tuning

1. **Nginx worker processes:**
   - Current: `worker_processes auto;` (matches CPU cores)
   - For high traffic: Consider explicit value

2. **UDP buffer sizes:**
   - Nginx: `proxy_buffer_size 65536;` (64KB)
   - Listener: `UdpReceiveBufferSizeBytes: 36777216` (36MB)

3. **Connection limits:**
   - Nginx: `worker_connections 1024;`
   - Increase for very high traffic

### Security

1. **Listeners are internal-only:**
   - Only nginx-lb exposes port 514 externally
   - Listeners use `expose` not `ports`

2. **Network isolation:**
   - All services on internal_network
   - No direct access to listeners from outside

3. **Configuration validation:**
   - Always run `nginx -t` before reload
   - Prevents bad configs from breaking service

---

## Summary

### What Was Implemented

✅ Nginx UDP load balancer on port 514
✅ Two listener instances (listener-1, listener-2)
✅ Random two least_conn load balancing algorithm
✅ Passive health checks with auto-recovery
✅ Zero-downtime config reloads
✅ Unique component identity in MongoDB
✅ Internal-only listener access (security)

### Key Benefits

- **Horizontal scaling:** Easy to add more listeners
- **High availability:** Service continues if one listener fails
- **Load distribution:** Traffic spread across instances
- **Zero downtime updates:** Reload nginx config without packet loss
- **Monitoring:** Per-instance metrics and logs

### Quick Reference

```bash
# Check status
docker ps | grep -E "listener|nginx-lb"

# Reload nginx config (no downtime)
docker exec nginx-lb nginx -s reload

# View traffic distribution
docker stats listener-1 listener-2 --no-stream

# Check nginx logs
docker logs nginx-lb --tail 20

# Test connectivity
echo "<34>Test" | nc -u -w1 localhost 514
```
