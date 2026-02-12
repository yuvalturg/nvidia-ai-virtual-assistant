#!/bin/bash
# AIVA OpenShift Deployment Script
# Deploys NVIDIA AI Virtual Assistant on OpenShift via a single helm install
# with all required OpenShift customizations.
#
# Usage:
#   NGC_API_KEY=your-key ./deploy-openshift.sh
#   NGC_API_KEY=your-key LLM_MODEL=meta/llama-3.1-8b-instruct LLM_IMAGE=nvcr.io/nim/meta/llama-3.1-8b-instruct ./deploy-openshift.sh
#   NGC_API_KEY=your-key GPU_TAINT_KEY=my-custom-gpu-taint ./deploy-openshift.sh
#
# What this does on top of the regular deploy.sh:
#   - Adds emptyDir volumes for stateful services (etcd, minio, postgres, milvus, cache, ingest)
#   - Adds GPU node tolerations for NIM and milvus deployments
#   - Removes NIM pod security contexts (lets OpenShift SCC manage UIDs)
#   - Swaps LLM image to a smaller model (default: 1B) and reduces GPU count
#   - Propagates model name to all dependent services
#   - Reduces ranking GPU from 2 to 1
#   - Enables HuggingFace offline mode for retrievers
#   - Exposes the UI via an OpenShift route

set -euo pipefail

: "${NGC_API_KEY:?Error: NGC_API_KEY environment variable is required. Get one at https://org.ngc.nvidia.com/setup/api-key}"
: "${NAMESPACE:?Error: NAMESPACE environment variable is required}"

# Configurable settings
LLM_MODEL="${LLM_MODEL:-meta/llama-3.1-8b-instruct}"
LLM_IMAGE="${LLM_IMAGE:-nvcr.io/nim/meta/llama-3.1-8b-instruct}"
LLM_IMAGE_TAG="${LLM_IMAGE_TAG:-latest}"
LLM_GPU_COUNT="${LLM_GPU_COUNT:-1}"
RANKING_GPU_COUNT="${RANKING_GPU_COUNT:-1}"
# Comma-separated list of toleration keys (e.g. "p4-gpu,g6-gpu")
GPU_TOLERATION_KEYS="${GPU_TOLERATION_KEYS:-nvidia.com/gpu}"
GPU_TOLERATION_EFFECT="${GPU_TOLERATION_EFFECT:-NoSchedule}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Deploying AIVA on OpenShift"
echo "  Namespace:  $NAMESPACE"
echo "  LLM Model:  $LLM_MODEL"
echo "  LLM Image:  $LLM_IMAGE:$LLM_IMAGE_TAG"
echo "  LLM GPUs:   $LLM_GPU_COUNT"
echo "  Tolerations: $GPU_TOLERATION_KEYS ($GPU_TOLERATION_EFFECT)"
echo ""

# Create namespace if needed
oc get namespace "$NAMESPACE" &>/dev/null || oc create namespace "$NAMESPACE"

# Create NGC docker registry secret if needed
oc get secret ngc-docker-reg-secret -n "$NAMESPACE" &>/dev/null || \
  oc create secret docker-registry ngc-docker-reg-secret \
    --docker-server=nvcr.io \
    --docker-username='$oauthtoken' \
    --docker-password="$NGC_API_KEY" \
    -n "$NAMESPACE"

# Build toleration --set args from comma-separated GPU_TOLERATION_KEYS
TOLERATION_ARGS=()
IFS=',' read -ra TKEYS <<< "$GPU_TOLERATION_KEYS"
for i in "${!TKEYS[@]}"; do
  key="${TKEYS[$i]}"
  for svc in milvus nemollm-inference nemollm-embedding ranking-ms; do
    TOLERATION_ARGS+=(
      --set "$svc.tolerations[$i].key=$key"
      --set "$svc.tolerations[$i].effect=$GPU_TOLERATION_EFFECT"
      --set "$svc.tolerations[$i].operator=Exists"
    )
  done
done

# Single helm install with all OpenShift overrides
helm upgrade --install aiva "$SCRIPT_DIR" \
  --namespace "$NAMESPACE" \
  -f "$SCRIPT_DIR/values-openshift.yaml" \
  --set global.ngcImagePullSecretName=ngc-docker-reg-secret \
  --set "ranking-ms.applicationSpecs.ranking-deployment.containers.ranking-container.env[0].name=NGC_API_KEY" \
  --set "ranking-ms.applicationSpecs.ranking-deployment.containers.ranking-container.env[0].value=$NGC_API_KEY" \
  --set "nemollm-inference.applicationSpecs.nemollm-infer-deployment.containers.nemollm-infer-container.env[0].name=NGC_API_KEY" \
  --set "nemollm-inference.applicationSpecs.nemollm-infer-deployment.containers.nemollm-infer-container.env[0].value=$NGC_API_KEY" \
  --set "nemollm-embedding.applicationSpecs.embedding-deployment.containers.embedding-container.env[0].name=NGC_API_KEY" \
  --set "nemollm-embedding.applicationSpecs.embedding-deployment.containers.embedding-container.env[0].value=$NGC_API_KEY" \
  "${TOLERATION_ARGS[@]}" \
  --set "pgadmin.replicas=0" \
  --set "nemollm-inference.applicationSpecs.nemollm-infer-deployment.securityContext.runAsUser=null" \
  --set "nemollm-inference.applicationSpecs.nemollm-infer-deployment.securityContext.runAsGroup=null" \
  --set "nemollm-embedding.applicationSpecs.embedding-deployment.securityContext.runAsUser=null" \
  --set "nemollm-embedding.applicationSpecs.embedding-deployment.securityContext.runAsGroup=null" \
  --set "ranking-ms.applicationSpecs.ranking-deployment.securityContext.runAsUser=null" \
  --set "ranking-ms.applicationSpecs.ranking-deployment.securityContext.runAsGroup=null" \
  --set "nemollm-inference.applicationSpecs.nemollm-infer-deployment.containers.nemollm-infer-container.image.repository=$LLM_IMAGE" \
  --set "nemollm-inference.applicationSpecs.nemollm-infer-deployment.containers.nemollm-infer-container.image.tag=$LLM_IMAGE_TAG" \
  --set "nemollm-inference.applicationSpecs.nemollm-infer-deployment.containers.nemollm-infer-container.resources.limits.nvidia\.com/gpu=$LLM_GPU_COUNT" \
  --set "ranking-ms.applicationSpecs.ranking-deployment.containers.ranking-container.resources.limits.nvidia\.com/gpu=$RANKING_GPU_COUNT" \
  --set "global.ucfGlobalEnv[0].name=APP_LLM_MODELNAME" \
  --set-string "global.ucfGlobalEnv[0].value=$LLM_MODEL" \
  --set "global.ucfGlobalEnv[1].name=HF_HUB_OFFLINE" \
  --set-string "global.ucfGlobalEnv[1].value=1"

# Expose UI via OpenShift route
oc expose svc/aiva-aiva-ui -n "$NAMESPACE" 2>/dev/null || true

ROUTE=$(oc get route aiva-aiva-ui -n "$NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null || true)
echo ""
echo "Deployment complete."
[ -n "$ROUTE" ] && echo "UI: http://$ROUTE"
echo "Monitor: oc get pods -n $NAMESPACE -w"
