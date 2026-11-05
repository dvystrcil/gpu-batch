#!/usr/bin/env bash
# Invariants of the RENDERED overlay (what Argo applies), beyond schema
# validity. Each guards a homelab#1935 decision; a change that breaks one
# should be argued in review, not slip through.
set -euo pipefail
cd "$(dirname "$0")/.."
out=$(kubectl kustomize overlays 2>/dev/null || kustomize build overlays)
fail() { echo "FAIL: $*"; exit 1; }
doc() { awk -v k="kind: $1" 'BEGIN{RS="\n---\n"} index($0, k) {print}' <<<"$out"; }
cj=$(doc CronJob)

# The template must never run by itself.
grep -q '^  suspend: true$' <<<"$cj" || fail "CronJob must be suspend: true (it is a template)"
grep -q "schedule: 0 0 31 2 \*" <<<"$cj" || fail "schedule must be the never-firing Feb 31"

# Bounded (AC2).
grep -q 'kubernetes.io/hostname: k8s-node-03' <<<"$cj" || fail "must pin to k8s-node-03 (the GTX 970)"
grep -q 'backoffLimit: 0' <<<"$cj" || fail "backoffLimit must be 0: a refusal must not be retried"
grep -q 'ttlSecondsAfterFinished:' <<<"$cj" || fail "ttlSecondsAfterFinished required"
dl=$(sed -n 's/^ *activeDeadlineSeconds: \([0-9]*\)$/\1/p' <<<"$cj")
[ -n "$dl" ] || fail "activeDeadlineSeconds required"
env_dl=$(grep -A1 'name: GPU_BATCH_DEADLINE_S' <<<"$cj" | sed -n 's/.*value: "\([0-9]*\)"/\1/p')
[ "$dl" = "$env_dl" ] || fail "GPU_BATCH_DEADLINE_S ($env_dl) must equal activeDeadlineSeconds ($dl): the runner reports a timeout only if it knows the real deadline"
grep -A3 'requests:' <<<"$cj" | grep -q 'cpu: 500m' || fail "cpu request must be 500m (node-03 has ~750m unrequested)"
grep -A3 'limits:' <<<"$cj" | grep -q 'memory:' || fail "memory limit required"
grep -A3 'limits:' <<<"$cj" | grep -q 'cpu:' && fail "no cpu limit (D-022)"
grep -q 'nvidia.com/gpu: 5' <<<"$cj" || fail "VRAM budget: 5 time-slice units (architecture/gpu-batch-lane.md); change both together"

# The guard and the completion channel are wired.
for v in MOONRAKER_URL OBICO_PG_SECRET GPU_BATCH_NOTIFY_URL; do
  grep -q "name: $v" <<<"$cj" || fail "$v must be set on the template"
done
grep -q 'istio.io/dataplane-mode: none' <<<"$cj" \
  || fail "Job pods must be off the ambient mesh: ztunnel turns a powered-off printer into a connection RESET, which the guard (correctly) reads as reachable/unknown and refuses"
grep -q 'claimName: gpu-batch-work' <<<"$cj" || fail "the work volume must be mounted"
grep -q 'runAsUser: 1000' <<<"$cj" || fail "uid 1000 = the laptop user that writes the job dirs"

# The work volume is the share the laptop mounts.
pv=$(doc PersistentVolume)
grep -q 'path: /mnt/pool/media/gpu-batch' <<<"$pv" || fail "PV must point at /mnt/pool/media/gpu-batch"
grep -q -- '- soft' <<<"$pv" || fail "NFS must be soft-mounted: hard hangs unkillably in a scrub stall and nothing reports"

grep -q '^kind: Secret$' <<<"$out" && fail "a literal Secret is rendered; use InfisicalSecret"
echo "RENDER-INVARIANTS-OK"
