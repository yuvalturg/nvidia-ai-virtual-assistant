# Deploying NVIDIA's AI Virtual Assistant Blueprint on OpenShift

It started simply enough: deploy NVIDIA's AI Virtual Assistant Blueprint on OpenShift. The blueprint ships with a `deploy.sh` that runs a single `helm install` — on vanilla Kubernetes, that's about all you need. On OpenShift, nothing worked out of the box.

OpenShift assigns random UIDs to containers, refuses to let them run as root or any hardcoded user, and enforces strict filesystem permissions through Security Context Constraints. The NIM containers expected to run as user 1000. The stateful services expected writable paths that didn't exist. The GPU nodes were tainted. And the Helm chart's value structure fought back against every override I tried.

What followed was an iterative process of deploying, watching pods crash, reading logs, and finding workarounds — some elegant, some less so. Each fix uncovered the next problem. This post documents that journey: every challenge, every dead end, and the deployment script that emerged from it.

## What We're Deploying

NVIDIA's AI Virtual Assistant (AIVA) Blueprint is a customer service application built on RAG (Retrieval-Augmented Generation). It combines:
- **LangGraph-based agents** for intelligent conversation routing
- **Dual RAG pipelines** for both structured (SQL) and unstructured (document) data retrieval
- **Vector search** via Milvus for semantic document matching
- **Multiple NIM microservices** for LLM inference, embeddings, and reranking
- **State management** through Redis and PostgreSQL
- **Modern web interface** built with Next.js

The architecture comprises 15+ interconnected microservices with carefully orchestrated dependencies and health checks.

## OpenShift-Specific Challenges and Solutions

### 1. Storage Persistence and Security Contexts

OpenShift's default Security Context Constraints prevent containers from running as root and enforce strict permissions on mounted volumes. This immediately surfaced issues with stateful services.

**Affected Services:**
- **etcd-etcd-deployment** - Cluster coordination and metadata storage (`/etcd`)
- **minio-minio-deployment** - Object storage for Milvus (`/minio_data`)
- **postgres-postgres-deployment** - Relational data and conversation checkpointing (`/var/lib/postgresql`)
- **milvus-milvus-deployment** - Vector database persistence (`/var/lib/milvus`)
- **cache-services-cache-deployment** - Session caching and temporary data (`/data`)
- **ingest-client-ingest-client-deployment** - Product data storage (`/opt/data/product`)

**Solution:**
For this deployment test, I used `emptyDir` volumes for rapid iteration and simplified troubleshooting. However, **for production deployments, PersistentVolumeClaims should be used** to ensure data durability across pod restarts and cluster maintenance.

```yaml
# Development/Testing approach (used in this deployment)
volumes:
- name: postgres-data
  emptyDir: {}

# Production approach (recommended)
volumes:
- name: postgres-data
  persistentVolumeClaim:
    claimName: postgres-pvc
```

Volume mounts configuration:
```yaml
# Example: PostgreSQL
volumeMounts:
- name: postgres-data
  mountPath: /var/lib/postgresql
```

The key insight: OpenShift's dynamic provisioners automatically set appropriate group ownership (GID 0) on volumes, making them writable by non-root containers—but only if volumes are declared at pod creation time.

### 2. GPU Scheduling and Tolerations

Many production Kubernetes clusters use node taints to segregate GPU workloads, ensuring specialized hardware is reserved for appropriate workloads. In my environment, nodes were tainted to prevent non-GPU pods from consuming GPU resources and to differentiate between GPU types for optimal resource allocation.

OpenShift's scheduler requires explicit tolerations in pod specifications to place workloads on tainted nodes.

**GPU-Dependent Services:**
- **milvus-milvus-deployment** - Requires GPU for vector similarity search acceleration
- **nemollm-inference-nemollm-infer-deployment** - Main language model serving
- **nemollm-embedding-embedding-deployment** - Vector embedding generation
- **ranking-ms-ranking-deployment** - Document reranking

**Example patches applied:**

```bash
# Milvus - GPU-accelerated vector search
# Uses high-performance GPU nodes for inference workloads
oc patch deployment milvus-milvus-deployment -p '{
  "spec": {
    "template": {
      "spec": {
        "tolerations": [{
          "key": "nvidia.com/gpu",
          "effect": "NoSchedule",
          "operator": "Exists"
        }]
      }
    }
  }
}'

# NeMo LLM Inference - Language model serving
oc patch deployment nemollm-inference-nemollm-infer-deployment -p '{
  "spec": {
    "template": {
      "spec": {
        "tolerations": [{
          "key": "nvidia.com/gpu",
          "effect": "NoSchedule",
          "operator": "Exists"
        }]
      }
    }
  }
}'

# Embedding and Ranking services
oc patch deployment nemollm-embedding-embedding-deployment -p '{
  "spec": {
    "template": {
      "spec": {
        "tolerations": [{
          "key": "nvidia.com/gpu",
          "effect": "NoSchedule",
          "operator": "Exists"
        }]
      }
    }
  }
}'

oc patch deployment ranking-ms-ranking-deployment -p '{
  "spec": {
    "template": {
      "spec": {
        "tolerations": [{
          "key": "nvidia.com/gpu",
          "effect": "NoSchedule",
          "operator": "Exists"
        }]
      }
    }
  }
}'
```

**Note:** The taint keys (`nvidia.com/gpu` in this example) will vary based on your cluster's node configuration. Common patterns include vendor-specific keys, GPU model identifiers, or custom organizational taints. Check your node labels and taints with `oc describe node <node-name>` to determine the appropriate toleration configuration.

### 3. Security Context Removal for NIM Containers

NVIDIA NIM containers are pre-configured with specific user/group IDs that conflict with OpenShift's random UID allocation. The solution required stripping security context definitions:

```bash
oc patch deployment nemollm-inference-nemollm-infer-deployment \
  -p '{"spec":{"template":{"spec":{"securityContext":null}}}}'
```

This allows OpenShift to inject its own security context via SCCs, ensuring compatibility while maintaining security posture.

### 4. Model Size Optimization

The default deployment specification loads the **Llama-3.1-70B** model, requiring substantial GPU memory (multiple A100 GPUs). For development and testing environments, this is prohibitively expensive.

**Optimization strategy:**

1. **Image substitution** - Changed from 70B to smaller variants:
   - `nvcr.io/nim/meta/llama-3.1-8b-instruct:latest` (8B parameters)
   - `nvcr.io/nim/meta/llama-3.2-1b-instruct:latest` (1B parameters)

2. **GPU allocation adjustment** - Reduced from 4 GPUs to 1 GPU:
   ```yaml
   resources:
     limits:
       nvidia.com/gpu: 1
   ```

3. **Model name propagation** - Updated `APP_LLM_MODELNAME` across all dependent services:
   - agent-services-agent-services-deployment
   - analytics-services-analytics-deployment
   - retriever-canonical-canonical-deployment
   - retriever-structured-structured-deployment

### 5. Offline Model Loading

The retriever services (**retriever-canonical-canonical-deployment** and **retriever-structured-structured-deployment**) download Hugging Face models (e.g., `Snowflake/snowflake-arctic-embed-l`) at runtime, causing:
- Slow startup times
- Network egress costs
- Potential failure if Hugging Face is unreachable

**Solution:**
The container images already include pre-downloaded models. Setting `HF_HUB_OFFLINE=1` forces the application to use cached models instead of attempting downloads:

```yaml
env:
- name: HF_HUB_OFFLINE
  value: "1"
```

### 6. Redis Persistence Permissions

The **cache-services-cache-deployment** includes Redis containers that attempted to write RDB snapshots to `/data`, failing due to OpenShift's permission model:

```
Failed opening the temp RDB file temp-198.rdb (in server root dir /data)
for saving: Permission denied
```

**Two approaches:**

**Option A: Disable persistence** (appropriate for cache-only workloads)
```yaml
command:
- redis-server
- --save ""
- --appendonly no
```

**Option B: Volume mount with proper permissions**
```yaml
# Testing approach (used in this deployment)
volumeMounts:
- name: redis-data
  mountPath: /data

volumes:
- name: redis-data
  emptyDir: {}

# Production approach (recommended)
volumes:
- name: redis-data
  persistentVolumeClaim:
    claimName: redis-pvc
```

I opted for the volume mount approach to maintain cache across restarts, improving user experience. For this test deployment, `emptyDir` was sufficient, but **production deployments should use PersistentVolumeClaims** to survive node failures and pod rescheduling.

### 7. Service Exposure

OpenShift routes provide ingress without requiring LoadBalancer services. To expose the UI to external traffic:

```bash
oc expose svc/aiva-aiva-ui
```

This creates an HTTPS-terminated route with automatic TLS certificate management via the cluster's ingress controller, making the application accessible at a cluster-assigned hostname.

## LLM Inference Options: A Comparison

Throughout the deployment, I evaluated three different approaches for LLM inference:

### Option 1: Self-Hosted NIM (Initial Approach)

**Configuration:**
```yaml
env:
- name: APP_LLM_SERVERURL
  value: "nemollm-inference-service:8000"
- name: APP_LLM_MODELNAME
  value: "meta/llama-3.2-1b-instruct"
```

**Pros:**
- Full control over infrastructure
- Data privacy (no external API calls)
- Predictable costs

**Cons:**
- Requires GPU resources
- Operational overhead (monitoring, updates)
- Limited to models that fit available GPU memory

### Option 2: Red Hat MaaS (Model-as-a-Service)

**Attempted Configuration:**
```yaml
env:
- name: APP_LLM_SERVERURL
  value: "deepseek-r1-qwen-14b-w4a16-maas-apicast-production.apps.prod.rhoai.rh-aiservices-bu.com:443"
- name: APP_LLM_MODELNAME
  value: "r1-qwen-14b-w4a16"
- name: NVIDIA_API_KEY
  value: "<api-key>"
```

**Blocker:**
The application's LLM client library (`langchain-nvidia-ai-endpoints`) hardcodes HTTP protocol:

```python
base_url=f"http://{settings.llm.server_url}/v1"
```

Red Hat MaaS requires HTTPS with TLS. Without the ability to rebuild container images, this approach was abandoned.

**Workaround (not implemented):**
An NGINX sidecar container could proxy HTTP→HTTPS:

```yaml
containers:
- name: https-proxy
  image: nginx:alpine
  volumeMounts:
  - name: nginx-config
    mountPath: /etc/nginx/nginx.conf
    subPath: nginx.conf
```

### Option 3: NVIDIA API Catalog (Final Choice)

**Configuration:**
```yaml
env:
- name: APP_LLM_SERVERURL
  value: ""  # Empty triggers API Catalog mode
- name: APP_LLM_MODELNAME
  value: "meta/llama-3.1-70b-instruct"  # Or any catalog model
- name: NVIDIA_API_KEY
  value: "<nvidia-api-key>"
```

When `APP_LLM_SERVERURL` is unset, the application defaults to NVIDIA's cloud-hosted models at `https://integrate.api.nvidia.com/v1`.

**Pros:**
- No GPU infrastructure required
- Access to dozens of models (Llama, Mistral, Gemma, DeepSeek)
- Instant scaling
- Always up-to-date models

**Cons:**
- Data leaves the cluster (compliance considerations)
- Pay-per-token pricing
- Network dependency

**Available models queried via:**
```bash
curl -H "Authorization: Bearer $NVIDIA_API_KEY" \
  https://integrate.api.nvidia.com/v1/models | jq '.data[].id'
```

This approach proved ideal for development and demonstration purposes.

## Architectural Insights

### GPU Node Affinity and Scheduling

The deployment leverages Kubernetes node taints and pod tolerations to ensure GPU workloads are scheduled on appropriate hardware. This prevents resource contention and ensures expensive GPU nodes are reserved for GPU-dependent workloads.

**Key scheduling patterns:**
- GPU-accelerated services include tolerations matching node taints
- Non-GPU services (postgres, redis, api-gateway, etc.) remain untainted
- Multiple GPU tiers can be supported using different taint keys

This scheduling strategy is critical in multi-tenant environments where GPU resources are shared across teams and projects.

### Service Dependency Chain

The deployment exhibits a clear initialization hierarchy:

```
Layer 1: Infrastructure
├─ postgres, minio, etcd, redis
└─ nemollm-inference, nemollm-embedding, ranking-ms

Layer 2: Vector Database
└─ milvus (waits for minio + etcd)

Layer 3: Retrievers
├─ retriever-canonical (waits for milvus + embedding + ranking + llm)
└─ retriever-structured (waits for milvus + embedding + ranking + llm)

Layer 4: Business Logic
├─ agent-services (waits for both retrievers + llm)
└─ ingest-client (waits for both retrievers)
└─ analytics-services (no dependencies)

Layer 5: API Layer
└─ api-gateway (waits for agent-services + analytics-services)

Layer 6: Frontend
└─ aiva-ui (waits for api-gateway)
```

Each service includes `initContainers` with health checks to enforce this ordering:

```yaml
initContainers:
- name: init-check
  command:
  - /bin/bash
  - -c
  - |
    until curl -sf http://upstream-service:port/health; do
      echo "Waiting for upstream service..."
      sleep 10
    done
```

### Data Flow: Question → Answer

1. **User submits question** via Next.js UI (port 3001)
2. **API Gateway** routes to appropriate service (port 9000)
3. **Agent Services** uses LangGraph to:
   - Classify intent (product question vs. order status vs. return)
   - Route to specialized assistant
4. **Retriever invocation**:
   - **Product questions** → `retriever-canonical:8086/search` (documents via Milvus)
   - **Order/returns** → `retriever-structured:8087/search` (SQL via VannaAI)
5. **Context aggregation** combines retrieval results with conversation history
6. **LLM generates response** using context-aware prompt
7. **Response streams back** through the stack to the user

## Lessons Learned

### 1. OpenShift Security Is Non-Negotiable

Attempting to bypass SCCs (e.g., requesting `privileged` SCC) is rarely approved and defeats the platform's security model. Instead:
- Design for random UIDs (1000000000+ range)
- Use group ownership (GID 0) for shared access
- Leverage `initContainers` for setup tasks requiring write access

### 2. GPU Allocation Matters

Overprovisioning GPUs wastes expensive resources. The application defaulted to 4 GPUs for the 70B model but only needed 1 GPU for the 1B model—a 75% reduction in GPU hours.

### 3. Offline-First for Air-Gapped Environments

Many enterprises deploy in air-gapped environments. Always verify that container images are self-contained:
```bash
# Test offline mode locally
docker run --network none <image> <command>
```

### 4. Protocol Assumptions Break Integrations

The HTTP-only limitation prevented MaaS integration. Modern applications should:
- Accept full URLs (including scheme) in configuration
- Support both HTTP and HTTPS
- Provide clear documentation on protocol requirements

### 5. EmptyDir vs. PersistentVolumes: Development vs. Production

For this test deployment, `emptyDir` volumes provided rapid iteration without the overhead of PVC provisioning and cleanup. However, this comes with significant tradeoffs:

**EmptyDir (Development/Testing):**
- ✅ Fast to provision and destroy
- ✅ No persistent storage quota concerns
- ✅ Simplified cleanup
- ❌ Data lost on pod restart/rescheduling
- ❌ Not suitable for production workloads

**PersistentVolumeClaims (Production):**
- ✅ Data survives pod lifecycle
- ✅ Survives node failures and maintenance
- ✅ Can be backed up and restored
- ✅ Performance guarantees (IOPS, throughput)
- ❌ Requires storage class configuration
- ❌ Quota management overhead

For production deployments of stateful services (PostgreSQL, Redis, Milvus, etcd, MinIO), **always use PersistentVolumeClaims** with appropriate storage classes and backup strategies.

### 8. Embedding NIM: HuggingFace Cache Permissions

The embedding NIM (`nvidia/llama-3.2-nv-embedqa-1b-v2`) attempted to write to `/.cache/huggingface/hub` at startup:

```
There was a problem when trying to write in your cache folder (/.cache/huggingface/hub).
You should set the environment variable TRANSFORMERS_CACHE to a writable directory.
```

OpenShift assigns a random UID with no home directory, so `~/.cache` resolves to `/.cache` (root's home), which is read-only on the container filesystem.

**Solution:**
Mount an emptyDir volume at `/.cache`:

```yaml
extraPodVolumes:
- name: hf-cache
  emptyDir: {}
extraPodVolumeMounts:
- name: hf-cache
  mountPath: /.cache
```

## Helm Override Challenges

Building the deployment script revealed several limitations in how Helm `--set` interacts with the chart's value structure. These are worth documenting since they affect anyone customizing this chart.

### Array Replacement vs. Element Modification

Helm's `--set` with array indices (e.g., `--set env[1].value=X`) does **not** modify a single element in an existing array. Instead, it creates a new array with only the specified indices populated and **replaces the entire original array**. For a service like `agent-services` with 23 environment variables, setting `env[1].value` would destroy the other 22 entries.

**Impact:** Environment variable overrides like `APP_LLM_MODELNAME` and `HF_HUB_OFFLINE` cannot be injected via `--set` on per-service env arrays.

**Solution:** The chart templates append `global.ucfGlobalEnv` after each container's own env vars. Since Kubernetes uses the **last occurrence** when duplicate env var names exist, global entries override per-container defaults:

```bash
--set "global.ucfGlobalEnv[0].name=APP_LLM_MODELNAME" \
--set-string "global.ucfGlobalEnv[0].value=meta/llama-3.1-8b-instruct" \
--set "global.ucfGlobalEnv[1].name=HF_HUB_OFFLINE" \
--set-string "global.ucfGlobalEnv[1].value=1"
```

Note the use of `--set-string` for values that look numeric. Without it, Helm treats `1` as an integer, and Kubernetes rejects the deployment because env var values must be strings:

```
Deployment in version "v1" cannot be handled as a Deployment:
json: cannot unmarshal number into Go struct field EnvVar.value of type string
```

### Map Nullification

The NIM containers ship with `securityContext: {runAsUser: 1000, runAsGroup: 1000}` in their chart values. The initial approach to clear this was:

```bash
--set "nemollm-inference.applicationSpecs.nemollm-infer-deployment.securityContext=null"
```

Helm refuses this because it cannot overwrite a map (table) with a non-map (null):

```
coalesce.go:298: warning: cannot overwrite table with non table for
  blueprint-aiva.nemollm-inference.applicationSpecs.nemollm-infer-deployment.securityContext
```

**Solution:** Null the individual fields instead, which Helm 3 handles correctly by removing each key:

```bash
--set "nemollm-inference.applicationSpecs.nemollm-infer-deployment.securityContext.runAsUser=null" \
--set "nemollm-inference.applicationSpecs.nemollm-infer-deployment.securityContext.runAsGroup=null"
```

This leaves an empty `securityContext: {}`, allowing OpenShift's SCC to manage UIDs.

### Values File vs. --set: When to Use Which

The deployment uses a hybrid approach:

| Mechanism | Used For | Why |
|-----------|----------|-----|
| Values file (`values-openshift.yaml`) | emptyDir volumes, HF cache mount | YAML objects like `emptyDir: {}` are awkward with `--set` |
| `--set` | NGC API keys, tolerations, security context, image/GPU overrides | Dynamic values from environment variables |
| `--set` with `global.ucfGlobalEnv` | Model name, HF offline mode | Appends to env arrays without replacing them |
| `--set-string` | Numeric env var values | Forces string type for Kubernetes compatibility |
| Post-install `oc expose` | UI route | No Route resource in the Helm chart |

## Automated Deployment Script

Rather than deploying with `helm install` and then applying patches with `oc patch` (the two-phase approach), the deployment script bakes all OpenShift customizations into a single `helm upgrade --install` command using a combination of a values override file and `--set` flags.

### How It Works

The script (`deploy-openshift.sh`) and its companion values file (`values-openshift.yaml`) are placed alongside NVIDIA's `deploy.sh` in `ai-virtual-assistant/deploy/helm/`.

**`values-openshift.yaml`** handles structural overrides that are cleanest in YAML:
- emptyDir volumes for all stateful services (etcd, minio, postgres, milvus, cache-services, ingest-client)
- Writable HF cache mount for the embedding NIM

**`deploy-openshift.sh`** handles everything else:
1. Creates the namespace and NGC docker registry secret if needed
2. Builds toleration `--set` args dynamically from a comma-separated list
3. Runs a single `helm upgrade --install` with all overrides
4. Exposes the UI via `oc expose`

### Usage

```bash
cd ai-virtual-assistant/deploy/helm/

# Basic deployment
NGC_API_KEY=your-key NAMESPACE=aiva ./deploy-openshift.sh

# Custom model
NGC_API_KEY=your-key NAMESPACE=aiva \
LLM_MODEL=meta/llama-3.2-1b-instruct \
LLM_IMAGE=nvcr.io/nim/meta/llama-3.2-1b-instruct \
./deploy-openshift.sh

# Multiple GPU tolerations
NGC_API_KEY=your-key NAMESPACE=aiva \
GPU_TOLERATION_KEYS="p4-gpu,g6-gpu" \
./deploy-openshift.sh
```

### Configuration Options

#### Required Variables

| Variable | Description |
|----------|-------------|
| `NGC_API_KEY` | NVIDIA NGC API key (get from https://org.ngc.nvidia.com/setup/api-key) |
| `NAMESPACE` | Target OpenShift namespace |

#### Optional Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `LLM_MODEL` | `meta/llama-3.1-8b-instruct` | Model name propagated to all services |
| `LLM_IMAGE` | `nvcr.io/nim/meta/llama-3.1-8b-instruct` | NIM inference container image |
| `LLM_IMAGE_TAG` | `latest` | NIM inference image tag |
| `LLM_GPU_COUNT` | `1` | GPUs allocated to LLM inference |
| `RANKING_GPU_COUNT` | `1` | GPUs allocated to ranking service |
| `GPU_TOLERATION_KEYS` | `nvidia.com/gpu` | Comma-separated toleration keys for GPU nodes |
| `GPU_TOLERATION_EFFECT` | `NoSchedule` | Toleration effect |

### What the Script Handles

The single helm install applies all of the following:

1. **Storage volumes** - emptyDir mounts for stateful services (via values file)
2. **HF cache** - Writable `/.cache` for embedding NIM (via values file)
3. **GPU tolerations** - Configurable, supports multiple keys (via `--set`)
4. **Security context** - Nullifies `runAsUser`/`runAsGroup` on NIM pods (via `--set`)
5. **Model configuration** - Image, tag, and GPU count for LLM inference (via `--set`)
6. **GPU reduction** - Ranking service reduced from 2 GPUs to 1 (via `--set`)
7. **Model name propagation** - `APP_LLM_MODELNAME` across all services (via `global.ucfGlobalEnv`)
8. **Offline mode** - `HF_HUB_OFFLINE=1` for all services (via `global.ucfGlobalEnv`)
9. **pgAdmin disabled** - Scaled to 0 replicas (via `--set`)
10. **UI route** - Exposed via `oc expose` post-install

### Monitoring Deployment Progress

```bash
# Watch pod status
oc get pods -n $NAMESPACE -w

# Check for unhealthy pods
oc get pods -n $NAMESPACE | grep -v Running | grep -v Completed

# View logs for a specific service
oc logs -f deployment/nemollm-embedding-embedding-deployment -n $NAMESPACE

# Check the UI route
oc get route aiva-aiva-ui -n $NAMESPACE
```

### Troubleshooting

**Pods stuck in Pending:**
- Verify GPU nodes are available: `oc get nodes -l nvidia.com/gpu`
- Check toleration keys match your node taints: `oc describe node <gpu-node>`
- Ensure NGC secret exists: `oc get secret ngc-docker-reg-secret -n $NAMESPACE`

**NIM containers crash with permission errors:**
- Verify security context was cleared: `oc get deployment <name> -o jsonpath='{.spec.template.spec.securityContext}'`
- Should show `{}` (empty), not `runAsUser: 1000`

**Embedding NIM thread exhaustion (`pthread_create failed`):**
- Check pod resource limits: `oc describe pod <embedding-pod>`
- Consider increasing CPU/memory limits for the embedding deployment
- Check node pid limits: `oc describe node <node> | grep -i pid`

**Storage permission denied:**
- Verify emptyDir volumes are mounted: `oc get deployment <name> -o yaml | grep -A5 volumeMounts`
- For production, switch to PVCs which automatically set GID 0

## Conclusion

Deploying NVIDIA's AI Virtual Assistant Blueprint on OpenShift requires addressing security constraints, GPU scheduling, storage permissions, and several Helm override quirks. The key challenges and their solutions:

- **OpenShift SCCs** prevent NIM containers from running with their hardcoded UIDs -- nullify the security context fields individually since Helm can't replace maps with null
- **Stateful services** need writable volumes -- emptyDir for testing, PVCs for production
- **GPU scheduling** requires tolerations matching node taints -- configurable via comma-separated keys
- **Helm `--set` replaces arrays** -- use `global.ucfGlobalEnv` to append env vars without destroying existing ones
- **Numeric env values** must be strings in Kubernetes -- use `--set-string`
- **Embedding NIM** needs a writable `/.cache` directory -- emptyDir volume mount

All customizations are codified in two files: `deploy-openshift.sh` (the deployment script) and `values-openshift.yaml` (structural overrides). Together they produce a single `helm upgrade --install` command that deploys the complete application with all OpenShift adaptations applied at install time, rather than patching after the fact.

## Technical Specifications

**Platform:** Red Hat OpenShift 4.x
**GPU Nodes:** P4 (inference), G6 (embeddings/ranking)
**Storage:** Dynamic PV provisioning via CSI
**Networking:** OpenShift Routes with TLS termination
**Container Runtime:** CRI-O

**Key Components:**
- NVIDIA NIM (LLM, Embedding, Ranking)
- Milvus 2.4.15-gpu
- PostgreSQL 14
- Redis 7
- Next.js 14
- LangChain + LangGraph

## Resources

**Deployment Files:**
- `deploy-openshift.sh` - Main deployment script
- `values-openshift.yaml` - Helm values override for OpenShift

Both files go in `ai-virtual-assistant/deploy/helm/` alongside NVIDIA's `deploy.sh`.

**Prerequisites:**
- OpenShift CLI (`oc`) installed and authenticated
- Helm 3.10+ installed
- NVIDIA GPU Operator installed on cluster
- NGC API key from https://org.ngc.nvidia.com/setup/api-key

**Quick Start:**
```bash
cd ai-virtual-assistant/deploy/helm/
NGC_API_KEY=your-key NAMESPACE=aiva ./deploy-openshift.sh
```

---

*This deployment serves as a reference architecture for production NVIDIA AI workloads on security-hardened Kubernetes platforms. The deployment script and values file provide a repeatable starting point for teams deploying similar architectures.*
