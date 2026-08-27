#!/usr/bin/env bash
# Run the LLM serving benchmark from a cluster node.
#
# Reads the LiteLLM key straight out of the cluster Secret so no credential is
# ever passed in on a command line or copied off the cluster.
#
#   ./run.sh                                  # default sweep
#   MODELS=qwen3.6-a3b,llama3.1-local ./run.sh
#   CONCURRENCY=1,2,4,8 REPS=3 ./run.sh
set -uo pipefail

KUBECTL=${KUBECTL:-kubectl}
HERE="$(cd "$(dirname "$0")" && pwd)"
RESULTS="${RESULTS:-$HERE/../results}"

MODELS=${MODELS:-qwen3.6-a3b}
CONCURRENCY=${CONCURRENCY:-1,2,4}
REPS=${REPS:-2}
MAX_TOKENS=${MAX_TOKENS:-256}
NODE_PORT=${NODE_PORT:-32500}
GPU_HOST=${GPU_HOST:-192.168.1.110}   # workstation running the GPU exporter

mkdir -p "$RESULTS"

KEY=$($KUBECTL get secret litellm-secrets -n ai \
        -o jsonpath='{.data.LITELLM_MASTER_KEY}' 2>/dev/null | base64 -d)
if [ -z "${KEY:-}" ]; then
    echo "Could not read LITELLM_MASTER_KEY from the litellm-secrets Secret." >&2
    exit 1
fi

URL="http://localhost:${NODE_PORT}"
if ! curl -sf -o /dev/null --max-time 5 "$URL/health/liveliness"; then
    echo "LiteLLM is not answering on $URL" >&2
    exit 1
fi

STAMP=$(date -u +%Y%m%d-%H%M%SZ)
OUT="$RESULTS/llm-$STAMP.json"

echo "models      : $MODELS"
echo "concurrency : $CONCURRENCY"
echo "reps        : $REPS   max_tokens: $MAX_TOKENS"
echo "results     : $OUT"

# Record what the GPU was doing beforehand - a benchmark run while something
# else is using the card is not comparable to one on an idle card.
if command -v curl >/dev/null; then
    busy=$(curl -s --max-time 5 "http://${GPU_HOST:-192.168.1.110}:9835/metrics" 2>/dev/null \
           | grep -m1 '^nvidia_smi_utilization_gpu_ratio' | awk '{print $2}')
    echo "gpu busy before: ${busy:-unknown}"
fi
echo

LITELLM_URL="$URL" LITELLM_KEY="$KEY" python3 "$HERE/bench.py" \
    --models "$MODELS" \
    --concurrency "$CONCURRENCY" \
    --reps "$REPS" \
    --max-tokens "$MAX_TOKENS" \
    --json-out "$OUT"
