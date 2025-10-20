# Spring Boot Pet Clinic - Kubernetes Deployment with Monitoring

## Project Overview

This project demonstrates containerizing and deploying the Spring Boot Pet Clinic application to a local Kubernetes cluster with comprehensive monitoring using Prometheus and Grafana. The implementation follows cloud-native best practices and provides a production-ready deployment template.

## Architecture Overview

### Why This Architecture?

The architecture follows the **twelve-factor app** methodology and cloud-native principles:

1. **Containerization**: Packages the application with all dependencies for consistency across environments
2. **Kubernetes Orchestration**: Provides automated deployment, scaling, and management
3. **Observability**: Prometheus and Grafana enable real-time monitoring and alerting
4. **Configuration Management**: Helm charts separate configuration from code

## Prerequisites

### System Requirements

- **RAM**: Minimum 8GB (16GB recommended)
- **Disk Space**: 10GB free
- **CPU**: 4 cores recommended

### Initial Setup

1. **Enable Kubernetes in Docker Desktop**:

   - Open Docker Desktop
   - Go to Settings → Kubernetes
   - Check "Enable Kubernetes"
   - Click "Apply & Restart"
   - Wait 3-5 minutes for Kubernetes to start

2. **Verify Installation**:

   ```bash
   # Check Docker is running
   docker ps

   # Check Kubernetes is running
   kubectl cluster-info

   # Check Helm is installed
   helm version
   ```

---

## Setup Instructions

### Part 1: Containerizing the Application

#### Why Docker?

Docker provides:

- **Consistency**: Same environment in dev, test, and production
- **Isolation**: No conflicts with other applications
- **Portability**: Runs anywhere Docker runs
- **Efficiency**: Lightweight compared to virtual machines

#### Step 1: Create the Dockerfile

Create `Dockerfile` in the project root:

```dockerfile
# Multi-stage build: Build and Runtime separated
# WHY: Reduces final image size by excluding build tools

# Stage 1: Build
FROM eclipse-temurin:17-jdk-jammy AS builder
WORKDIR /workspace
COPY . .
# Build with Maven wrapper (included in Pet Clinic repo)
RUN ./mvnw clean package -DskipTests

# Stage 2: Runtime
FROM eclipse-temurin:17-jre-jammy
# WHY: JRE is smaller than JDK (we don't need compilation tools at runtime)

# Create non-root user for security
# WHY: Running as root is a security risk
RUN useradd -m -u 1000 appuser

WORKDIR /app
COPY --from=builder --chown=appuser:appuser /workspace/target/*.jar app.jar

USER appuser
EXPOSE 8080

# Run with configurable environment variables
# WHY: Allows same image to run in different environments (dev/prod)
ENTRYPOINT ["sh", "-c", "java -jar app.jar \
  --server.port=${SERVER_PORT:-8080} \
  --server.servlet.context-path=${CONTEXT_PATH:-/} \
  --management.endpoints.web.exposure.include=${MANAGEMENT_ENDPOINTS:-health,metrics,prometheus}"]
```

#### Step 2: Build the Docker Image

```bash
# Build the image
# WHY: Creates a portable container image from source code
docker build -t pet-clinic:1.0.0 .

# Verify the image was created
docker images | grep pet-clinic

# Test locally (optional but recommended)
docker run -p 8080:8080 pet-clinic:1.0.0
# Open http://localhost:8080 in browser
```

#### Environment Variables Explained

| Variable               | Default                   | Purpose                            |
| ---------------------- | ------------------------- | ---------------------------------- |
| `SERVER_PORT`          | 8080                      | Port where Spring Boot listens     |
| `CONTEXT_PATH`         | /                         | URL path prefix (e.g., /petclinic) |
| `MANAGEMENT_ENDPOINTS` | health,metrics,prometheus | Which actuator endpoints to expose |

**Why environment variables?**

- Change configuration without rebuilding the image
- Different settings for dev/staging/production
- Follows twelve-factor app principles

---

### Part 2: Creating the Helm Chart

#### Why Helm?

Helm is like a package manager (npm, apt, brew) for Kubernetes:

- **Templating**: Reuse configurations with different values
- **Versioning**: Track changes and rollback if needed
- **Dependencies**: Manage related services together
- **Simplicity**: One command to deploy multiple Kubernetes resources

#### Step 1: Create the Chart Structure

```bash
# Generate a basic chart structure
# WHY: Helm's scaffolding provides best-practice templates
helm create pet-clinic-chart

# Clean up files we don't need for this simple deployment
rm -rf pet-clinic-chart/templates/tests/
rm pet-clinic-chart/templates/hpa.yaml
rm pet-clinic-chart/templates/ingress.yaml
```

#### Step 2: Configure values.yaml

Edit `pet-clinic-chart/values.yaml`:

```yaml
# Number of pod replicas
# WHY: 2 replicas provide high availability (if one fails, other handles traffic)
replicaCount: 2

image:
  repository: pet-clinic
  pullPolicy: IfNotPresent # Use local image if available
  tag: "1.0.0"

serviceAccount:
  create: false # Not needed for simple deployment

service:
  type: ClusterIP # Internal-only service (not exposed outside cluster)
  port: 80 # Service listens on port 80
  targetPort: 8080 # Forwards to container port 8080

# Resource limits prevent one pod from consuming all cluster resources
resources:
  limits:
    cpu: 500m # Max 0.5 CPU cores
    memory: 1Gi # Max 1 GB RAM
  requests:
    cpu: 250m # Guaranteed 0.25 CPU cores
    memory: 512Mi # Guaranteed 512 MB RAM

# Health checks enable Kubernetes to automatically recover from failures
livenessProbe:
  httpGet:
    path: /actuator/health
    port: 8080
  initialDelaySeconds: 90 # Wait 90s for Spring Boot to start
  periodSeconds: 10 # Check every 10s
  failureThreshold: 5 # Restart after 5 failed checks

readinessProbe:
  httpGet:
    path: /actuator/health/readiness
    port: 8080
  initialDelaySeconds: 45 # Wait 45s before accepting traffic
  periodSeconds: 5 # Check every 5s

# Application environment variables
env:
  SERVER_PORT: "8080"
  CONTEXT_PATH: "/"
  MANAGEMENT_ENDPOINTS: "health,metrics,prometheus"

# Prometheus configuration
serviceMonitor:
  enabled: true
  interval: 30s
  path: /actuator/prometheus
```

#### Step 3: Update deployment.yaml for Environment Variables

Edit `pet-clinic-chart/templates/deployment.yaml` and add environment variables in the container spec:

```yaml
env:
  - name: SERVER_PORT
    value: "{{ .Values.env.SERVER_PORT }}"
  - name: CONTEXT_PATH
    value: "{{ .Values.env.CONTEXT_PATH }}"
  - name: MANAGEMENT_ENDPOINTS
    value: "{{ .Values.env.MANAGEMENT_ENDPOINTS }}"
```

#### Step 4: Create ServiceMonitor for Prometheus

Create `pet-clinic-chart/templates/servicemonitor.yaml`:

```yaml
{{- if .Values.serviceMonitor.enabled }}
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: {{ include "pet-clinic.fullname" . }}
  labels:
    {{- include "pet-clinic.labels" . | nindent 4 }}
    release: prometheus  # CRITICAL: Tells Prometheus Operator to discover this
spec:
  selector:
    matchLabels:
      {{- include "pet-clinic.selectorLabels" . | nindent 6 }}
  endpoints:
  - port: http
    path: {{ .Values.serviceMonitor.path }}
    interval: {{ .Values.serviceMonitor.interval }}
{{- end }}
```

**Why ServiceMonitor?**

- Tells Prometheus where to scrape metrics
- Automatically discovered by Prometheus Operator
- No manual Prometheus configuration needed

#### Step 5: Validate the Chart

```bash
# Check for syntax errors and best practice violations
helm lint ./pet-clinic-chart

# Preview what will be deployed (dry-run)
helm template pet-clinic ./pet-clinic-chart

# Should show all Kubernetes manifests that will be created
```

---

### Part 3: Deploying to Kubernetes

#### Step 1: Create Namespace

```bash
# Namespaces provide isolation between applications
kubectl create namespace pet-clinic
```

**Why namespaces?**

- Organize resources logically
- Apply different RBAC policies
- Isolate resources (quotas, network policies)

#### Step 2: Deploy with Helm

```bash
# Install the application
helm install pet-clinic ./pet-clinic-chart --namespace pet-clinic

# Verify deployment
helm list -n pet-clinic
kubectl get all -n pet-clinic
```

#### Step 3: Access the Application

```bash
# Port forward to access locally
# WHY: ClusterIP services are only accessible within the cluster
kubectl port-forward -n pet-clinic svc/pet-clinic 8080:80

# Open in browser: http://localhost:8080
# Or test with curl:
curl http://localhost:8080
```

#### Step 4: Verify Health Endpoints

```bash
# Check health endpoint
curl http://localhost:8080/actuator/health

# Check Prometheus metrics
curl http://localhost:8080/actuator/prometheus | head -20
```

---

## Monitoring Setup

### Part 4: Installing Prometheus and Grafana

#### Why Prometheus and Grafana?

- **Prometheus**: Industry-standard metrics collection for Kubernetes
  - Pull-based model (Prometheus scrapes applications)
  - Efficient time-series storage
  - Powerful query language (PromQL)
- **Grafana**: Visualization and dashboards
  - Beautiful, interactive charts
  - Alerting capabilities
  - Multiple data source support

#### Step 1: Add Helm Repositories

```bash
# Add Prometheus community charts
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts

# Add Grafana charts
helm repo add grafana https://grafana.github.io/helm-charts

# Update repository cache
helm repo update
```

#### Step 2: Create Monitoring Namespace

```bash
kubectl create namespace monitoring
```

#### Step 3: Install Prometheus Stack

Create `monitoring/prometheus-values.yaml`:

```yaml
prometheus:
  prometheusSpec:
    # How long to keep metrics
    retention: 15d

    # Resource limits for Prometheus pod
    resources:
      requests:
        cpu: 100m
        memory: 500Mi
      limits:
        cpu: 500m
        memory: 2Gi

    # Discover ServiceMonitors in all namespaces
    serviceMonitorSelector: {}
    serviceMonitorNamespaceSelector: {}

# Enable Grafana as part of the stack
grafana:
  enabled: true
  adminPassword: admin # CHANGE THIS IN PRODUCTION!
  persistence:
    enabled: true
    size: 1Gi
```

Install the stack:

```bash
helm install prometheus prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --values monitoring/prometheus-values.yaml
```

#### Step 4: Verify Prometheus is Scraping Pet Clinic

```bash
# Port forward to Prometheus UI
kubectl port-forward -n monitoring svc/prometheus-kube-prometheus-prometheus 9090:9090

# Open http://localhost:9090
# Navigate to: Status → Targets
# Look for "pet-clinic" - should show "UP" status
```

**Troubleshooting**: If Pet Clinic doesn't appear:

1. Check ServiceMonitor has `release: prometheus` label
2. Verify ServiceMonitor selector matches Service labels
3. Wait 30 seconds for Prometheus to reload configuration

---

### Part 5: Creating Grafana Dashboards

#### Step 1: Access Grafana

```bash
# Port forward to Grafana
kubectl port-forward -n monitoring svc/prometheus-grafana 3000:80

# Open http://localhost:3000
# Login: admin / admin (or your configured password)
```

#### Step 2: Add Prometheus Data Source

**Why this step?** Grafana needs to know where to fetch metrics from.

1. Click ⚙️ **Configuration** → **Data Sources**
2. Click **"Add data source"**
3. Select **Prometheus**
4. Set URL: `http://prometheus-kube-prometheus-prometheus.monitoring.svc.cluster.local:9090`
5. Click **"Save & test"** (should show green success message)

**Note**: This URL uses Kubernetes DNS:

- `prometheus-kube-prometheus-prometheus` = service name
- `monitoring` = namespace
- `svc.cluster.local` = Kubernetes cluster domain

#### Step 3: Create a New Dashboard

1. Click **+** → **Dashboard**
2. Click **"Add new panel"**

#### Step 4: Create Monitoring Panels

Create the following panels (each demonstrates different aspects of monitoring):

##### Panel 1: JVM Heap Memory Usage

**Purpose**: Monitor memory consumption to detect memory leaks

**Configuration**:

- **Query**: `jvm_memory_used_bytes{area="heap"}`
- **Visualization**: Time series (line graph)
- **Unit**: bytes (IEC)
- **Title**: "JVM Heap Memory Usage"
- **Description**: "Heap memory consumption over time. Look for sawtooth pattern (memory grows, then drops after GC)"

**What to look for**:

- **Normal**: Sawtooth pattern (grows, then GC drops it)
- **Problem**: Continuous growth without drops = memory leak

##### Panel 2: Garbage Collection Time

**Purpose**: Monitor how much time is spent on garbage collection

**Configuration**:

- **Query**: `rate(jvm_gc_pause_seconds_sum[1m])`
- **Visualization**: Time series
- **Unit**: seconds
- **Title**: "GC Time per Minute"
- **Description**: "Time spent in garbage collection per minute. High values indicate GC pressure"

**What to look for**:

- **Normal**: < 0.1 seconds per minute
- **Warning**: 0.1 - 0.5 seconds
- **Critical**: > 0.5 seconds (significant performance impact)

##### Panel 3: HTTP Request Rate

**Purpose**: Monitor application throughput

**Configuration**:

- **Query**: `rate(http_server_requests_seconds_count[5m])`
- **Visualization**: Time series
- **Unit**: requests/sec
- **Title**: "HTTP Request Rate"
- **Description**: "Requests per second. Helps understand traffic patterns and capacity"

##### Panel 4: HTTP Error Rate

**Purpose**: Detect application errors quickly

**Configuration**:

- **Query**: `rate(http_server_requests_seconds_count{status=~"5.."}[1m])`
- **Visualization**: Stat (single number)
- **Unit**: requests/sec
- **Title**: "HTTP 5xx Errors"
- **Description**: "Server errors per second. Should be zero or very low"
- **Threshold**: Red if > 0

##### Panel 5: Request Duration (P95)

**Purpose**: Monitor application response time

**Configuration**:

- **Query**: `histogram_quantile(0.95, rate(http_server_requests_seconds_bucket[5m]))`
- **Visualization**: Time series
- **Unit**: seconds
- **Title**: "Response Time (95th percentile)"
- **Description**: "95% of requests complete within this time"

**What to look for**:

- **Good**: < 0.5 seconds
- **Acceptable**: 0.5 - 2 seconds
- **Poor**: > 2 seconds

##### Panel 6: Application Uptime

**Purpose**: Track application availability

**Configuration**:

- **Query**: `process_uptime_seconds`
- **Visualization**: Stat
- **Unit**: seconds
- **Title**: "Application Uptime"
- **Description**: "Time since application started"

#### Step 5: Save the Dashboard

1. Click **"Save dashboard"** icon (💾) at top
2. Name it: **"Pet Clinic Monitoring"**
3. Click **"Save"**

#### Step 6: Export Dashboard (for sharing)

1. Click ⚙️ **Dashboard settings**
2. Click **"JSON Model"**
3. Copy the JSON
4. Save to `monitoring/grafana-dashboards/pet-clinic-dashboard.json`

---

## Troubleshooting

#### Issue 1: Pods Keep Restarting

**Symptoms**:

```bash
kubectl get pods -n pet-clinic
# Shows high RESTARTS count
```

**Causes and Solutions**:

1. **Liveness probe failing too early**

   - **Fix**: Increase `initialDelaySeconds` to 90+ seconds
   - **Why**: Spring Boot needs time to start

2. **Out of memory**

   - **Fix**: Increase `resources.limits.memory` to 1Gi or more
   - **Check**: `kubectl describe pod -n pet-clinic <pod-name>` (look for OOMKilled)

3. **Application crash**
   - **Check logs**: `kubectl logs -n pet-clinic <pod-name> --previous`
   - **Fix**: Address the specific error in logs

#### Issue 2: Image Pull Errors

**Symptoms**:

```
ErrImagePull
ImagePullBackOff
ErrImageNeverPull
```

**Solutions**:

1. **Image doesn't exist locally**

   ```bash
   # Build the image
   docker build -t pet-clinic:1.0.0 .
   ```

2. **Wrong pullPolicy**
   - Set `pullPolicy: Never` in values.yaml
   - **Never use**: `pullPolicy: Always` for local development

#### Issue 3: Grafana Shows "No Data"

**Diagnostic steps**:

1. **Check Pod is running**:

   ```bash
   kubectl get pods -n pet-clinic
   ```

2. **Check actuator endpoint**:

   ```bash
   kubectl port-forward -n pet-clinic svc/pet-clinic 8080:80
   curl http://localhost:8080/actuator/prometheus
   ```

3. **Check Prometheus is scraping**:

   - Open Prometheus UI (port-forward to 9090)
   - Go to Status → Targets
   - Verify Pet Clinic target shows "UP"

4. **Check ServiceMonitor**:

   ```bash
   kubectl get servicemonitor -n pet-clinic
   kubectl describe servicemonitor -n pet-clinic
   ```

   - Must have `release: prometheus` label
   - Selector must match Service labels

5. **Check Prometheus can reach the service**:
   ```bash
   # From a debug pod
   kubectl run -it --rm debug --image=curlimages/curl --restart=Never -- \
     curl http://pet-clinic.pet-clinic.svc.cluster.local/actuator/prometheus
   ```

#### Issue 4: Helm Lint Errors

**Common errors**:

1. **"nil pointer evaluating interface"**

   - **Cause**: Missing value in values.yaml
   - **Fix**: Add the missing section (e.g., serviceAccount, ingress)

2. **"template not found"**

   - **Cause**: Template name mismatch in \_helpers.tpl
   - **Fix**: Ensure names match (e.g., "pet-clinic.fullname" vs "pet-clinic-chart.fullname")

3. **"unable to parse YAML"**
   - **Cause**: Syntax error (usually indentation or tabs)
   - **Fix**: Use `cat -A file.yaml` to see hidden characters, fix indentation

---

## Worklog

### Time Tracking

Task Time Spent
Environment Setup 30 min

- Install Docker Desktop, enable Kubernetes 15 min
- Install Helm, verify tools 15 min
  Dockerfile Creation 45 min
- Research multi-stage builds 15 min
- Write Dockerfile with env variables 20 min
- Build and test image locally 10 min
  Helm Chart Development 90 min
- Create chart structure 10 min
- Configure values.yaml 20 min
- Create/update templates 30 min
- Debug lint errors (multiple iterations) 30 min
  Kubernetes Deployment 30 min
- Create namespace 2 min
- Deploy with Helm 5 min
- Troubleshoot pod restart issues 20 min
- Verify application access 3 min
  Prometheus & Grafana Setup 60 min
- Install Prometheus stack 15 min
- Configure ServiceMonitor 20 min
- Troubleshoot scraping issues 15 min
- Install Grafana 10 min
  Dashboard Creation 45 min
- Create 6 monitoring panels 30 min
- Configure queries and visualizations 10 min
- Export dashboard JSON 5 min
  Documentation 60 min
- Write README with explanations 45 min
- Create troubleshooting guide 15 min
  TOTAL 5 hours

### Key Challenges Encountered

#### 1. Helm Chart Naming Inconsistencies

**Problem**: Template files referenced `pet-clinic-chart.fullname` but `_helpers.tpl` defined `pet-clinic.fullname`.

**Solution**:

- Learned about Helm naming conventions
- Fixed by standardizing on `pet-clinic.` prefix
- Documented the importance of consistent naming

**Learning**: Always use `helm lint` early and often. Small naming mismatches cause cascading errors.

#### 2. Pod Restart Loop

**Problem**: Pods restarted 20+ times with `CrashLoopBackOff`.

**Root Cause**: Liveness probe checked `/actuator/health` before Spring Boot finished starting.

**Solution**:

- Increased `initialDelaySeconds` from 30s to 90s
- Added `failureThreshold: 5` for more tolerance
- Spring Boot needs 60-90 seconds to fully start

**Learning**: Health checks are essential but need proper timing. Too aggressive = restart loops.

**Problem**: Init:CrashLoopBackOff status on the Grafana pod

**Solution**:
Stop the Failing Pod/Deployment:

`kubectl delete deployment prometheus-grafana -n monitoring`

`kubectl delete pvc prometheus-grafana -n monitoring`

`helm install prometheus prometheus-community/kube-prometheus-stack --namespace monitoring --create-namespace --values prometheus-values.yaml --replace`

Wait 2-3 minutes and check the status.

#### 3. Prometheus Not Scraping Metrics

**Problem**: Grafana showed "No Data" even though application was running.

**Root Cause**: ServiceMonitor missing `release: prometheus` label.

**Solution**:

- Added label to ServiceMonitor metadata
- Prometheus Operator uses this label to discover targets
- Verified in Prometheus UI (Status → Targets)

**Learning**: Kubernetes Operators use label selectors extensively. Labels are critical for service discovery.

### Deferred Tasks

Due to time constraints, the following were not implemented but would be valuable additions:

1. **Horizontal Pod Autoscaler (HPA)**

   - Automatically scale pods based on CPU/memory
   - Configuration already in values.yaml, just set `autoscaling.enabled: true`
   - **Why**: Essential for production to handle traffic spikes

2. **Ingress Controller**

   - Expose application externally with proper domain name
   - TLS/SSL certificate for HTTPS
   - **Why**: Port-forwarding is only for development

3. **Persistent Storage for H2 Database**

   - Add PersistentVolumeClaim for database data
   - Current setup loses data on pod restart
   - **Why**: Production needs data persistence

4. **Alerting Rules**
   - Configure Prometheus AlertManager
   - Alert on: high memory, error rate, pod restarts
   - Integration with Slack/PagerDuty
