#!/usr/bin/env bash
# Invariants of the RENDERED overlay (what Argo applies), beyond schema
# validity. Each guards a homelab#1935 decision; a change that breaks one
# should be argued in review, not slip through.
set -euo pipefail
cd "$(dirname "$0")/.."
out=$(kubectl kustomize overlays 2>/dev/null || kustomize build overlays)
fail() { echo "FAIL: $*"; exit 1; }
doc() { awk -v k="kind: $1" 'BEGIN{RS="\n---\n"} index($0, k) {print}' <<<"$out"; }
# One doc per Job template, by name. Every template gets the common checks;
# a check on the concatenation of all of them would pass on either one.
cron() { awk -v n="  name: $1" 'BEGIN{RS="\n---\n"} /(^|\n)kind: CronJob\n/ && index($0, "\n" n "\n") {print}' <<<"$out"; }
# The resources.limits block of the (single) container, up to the next key at its indent.
limits() { awk '/^ *limits:$/{f=1; i=index($0,"l"); next} f{ if (index($0,$1)<=i) exit; print }' <<<"$1"; }
names=$(awk 'BEGIN{RS="\n---\n"} /(^|\n)kind: CronJob\n/ {if (match($0, /\n  name: [a-z0-9-]+\n/)) print substr($0, RSTART+9, RLENGTH-10)}' <<<"$out")
[ "$(sort <<<"$names" | tr '\n' ' ')" = "blender-render freecad-sweep " ] \
  || fail "templates must be exactly blender-render and freecad-sweep (got: $(tr '\n' ' ' <<<"$names")); add the new one's checks below"

common() {
  local t=$1 cj; cj=$(cron "$1")
  [ -n "$cj" ] || fail "$t: template missing"
  # The template must never run by itself.
  grep -q '^  suspend: true$' <<<"$cj" || fail "$t: CronJob must be suspend: true (it is a template)"
  grep -q "schedule: 0 0 31 2 \*" <<<"$cj" || fail "$t: schedule must be the never-firing Feb 31"
  grep -q 'backoffLimit: 0' <<<"$cj" || fail "$t: backoffLimit must be 0: a refusal must not be retried"
  grep -q 'ttlSecondsAfterFinished:' <<<"$cj" || fail "$t: ttlSecondsAfterFinished required"
  local dl env_dl
  dl=$(sed -n 's/^ *activeDeadlineSeconds: \([0-9]*\)$/\1/p' <<<"$cj")
  [ -n "$dl" ] || fail "$t: activeDeadlineSeconds required"
  env_dl=$(grep -A1 'name: GPU_BATCH_DEADLINE_S' <<<"$cj" | sed -n 's/.*value: "\([0-9]*\)"/\1/p')
  [ "$dl" = "$env_dl" ] || fail "$t: GPU_BATCH_DEADLINE_S ($env_dl) must equal activeDeadlineSeconds ($dl): the runner reports a timeout only if it knows the real deadline"
  limits "$cj" | grep -q 'memory:' || fail "$t: memory limit required"
  limits "$cj" | grep -q 'cpu:' && fail "$t: no cpu limit (D-022)"
  # The guard and the completion channel are wired.
  for v in MOONRAKER_URL OBICO_PG_SECRET GPU_BATCH_NOTIFY_URL; do
    grep -q "name: $v" <<<"$cj" || fail "$t: $v must be set on the template"
  done
  grep -q 'istio.io/dataplane-mode: none' <<<"$cj" \
    || fail "$t: Job pods must be off the ambient mesh: ztunnel turns a powered-off printer into a connection RESET, which the guard (correctly) reads as reachable/unknown and refuses"
  grep -q 'claimName: gpu-batch-work' <<<"$cj" || fail "$t: the work volume must be mounted"
  grep -q 'runAsUser: 1000' <<<"$cj" || fail "$t: uid 1000 = the laptop user that writes the job dirs"
  grep -q "image: harbor.sirddail.net/ai/gpu-batch-" <<<"$cj" || fail "$t: image must be a gpu-batch-* Harbor image (the trigger VAP allows only those)"
}
common blender-render
common freecad-sweep

# The runner records its image in status.json from GPU_BATCH_IMAGE, and a pod
# cannot read its own image (the Downward API has no image fieldRef). n8n's
# "Create Job from CronJob" copies the jobTemplate as-is, so the value must be
# IN the template, equal to the image Argo applies, tag included (gpu-batch#16).
image_env() {
  local t=$1 cj img env_img; cj=$(cron "$1")
  img=$(sed -n 's/^ *image: //p' <<<"$cj")
  env_img=$(grep -A1 'name: GPU_BATCH_IMAGE$' <<<"$cj" | sed -n 's/^ *value: //p' || true)
  [ -n "$img" ] || fail "$t: no container image rendered"
  [[ "$img" == *:* ]] || fail "$t: image $img has no tag: the overlay's images: entry did not apply"
  [ "$env_img" = "$img" ] \
    || fail "$t: GPU_BATCH_IMAGE (${env_img:-unset}) must equal the container image ($img); see overlays/ replacements"
}
image_env blender-render
image_env freecad-sweep
# And it follows a tag bump (the docker-release bot edits only newTag lines):
# replacements must run on the tag the images: transformer set, not before it.
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
cp -r base cluster overlays "$tmp"/
sed -i 's/^  newTag: .*/  newTag: 9.9.9-render-test/' "$tmp/overlays/kustomization.yaml"
bumped=$(kubectl kustomize "$tmp/overlays" 2>/dev/null || kustomize build "$tmp/overlays")
for t in blender-render freecad-sweep; do
  grep -A1 'name: GPU_BATCH_IMAGE$' <<<"$(out=$bumped cron "$t")" | grep -q "value: .*:9.9.9-render-test$" \
    || fail "$t: GPU_BATCH_IMAGE did not follow a newTag bump"
done

# Blender: the GTX 970 (homelab#1935 AC2).
b=$(cron blender-render)
grep -q 'kubernetes.io/hostname: k8s-node-03' <<<"$b" || fail "blender-render: must pin to k8s-node-03 (the GTX 970)"
grep -A3 'requests:' <<<"$b" | grep -q 'cpu: 500m' || fail "blender-render: cpu request must be 500m (node-03 has ~750m unrequested)"
limits "$b" | grep -q 'nvidia.com/gpu: 5' || fail "blender-render: VRAM budget: 5 time-slice units (architecture/gpu-batch-lane.md); change both together"
grep -q 'GPU_BATCH_PRINT_GUARD' <<<"$b" && fail "blender-render: never set GPU_BATCH_PRINT_GUARD on the GPU template (the runner ignores it there anyway)"

# FreeCAD: CPU-only on max-01 (homelab#1974).
f=$(cron freecad-sweep)
grep -q 'kubernetes.io/hostname: k8s-node-max-01' <<<"$f" || fail "freecad-sweep: must pin to k8s-node-max-01 (node-03 cannot fit 10 workers)"
grep -A3 'tolerations:' <<<"$f" | grep -q 'key: ollama' || fail "freecad-sweep: must tolerate max-01's ollama taint"
grep -q 'nvidia.com/gpu' <<<"$f" && fail "freecad-sweep: CPU-only; a GPU would also re-enable the print guard"
grep -A1 'name: GPU_BATCH_PRINT_GUARD' <<<"$f" | grep -q 'value: "off"' || fail "freecad-sweep: GPU_BATCH_PRINT_GUARD must be \"off\" (no GPU to protect)"
grep -A3 'requests:' <<<"$f" | grep -q 'memory: 10Gi' || fail "freecad-sweep: memory request 10Gi, from the 9.45 GiB lite-26 peak"
limits "$f" | grep -q 'memory: 12Gi' || fail "freecad-sweep: memory limit 12Gi"

# The work volume is the share the laptop mounts.
pv=$(doc PersistentVolume)
grep -q 'path: /mnt/pool/media/gpu-batch' <<<"$pv" || fail "PV must point at /mnt/pool/media/gpu-batch"
grep -q -- '- soft' <<<"$pv" || fail "NFS must be soft-mounted: hard hangs unkillably in a scrub stall and nothing reports"

grep -q '^kind: Secret$' <<<"$out" && fail "a literal Secret is rendered; use InfisicalSecret"

# n8n's batch trigger (homelab#1961 AC2). Exact-kind match: `kind: Role`
# is also a substring of RoleBinding docs and their roleRef.
kdoc() { awk -v k="$1" 'BEGIN{RS="\n---\n"} $0 ~ ("(^|\n)kind: " k "\n") {print}' <<<"$out"; }
role=$(kdoc Role)
[ -n "$role" ] || fail "Role n8n-batch-trigger missing"
rules=$(sed -n '/^rules:/,$p' <<<"$role" | tr -d ' \n')
want='rules:-apiGroups:-batchresources:-cronjobsverbs:-get-apiGroups:-batchresources:-jobsverbs:-create-get-apiGroups:-""resources:-podsverbs:-list-apiGroups:-""resources:-pods/logverbs:-get'
[ "$rules" = "$want" ] || fail "n8n-batch-trigger Role must be exactly: get cronjobs; create,get jobs; list pods; get pods/log (got: $rules)"
rb=$(kdoc RoleBinding)
grep -q 'name: n8n-batch-trigger' <<<"$rb" && grep -q 'namespace: n8n-workflow' <<<"$rb" \
  || fail "RoleBinding must bind the SA n8n-workflow/n8n-batch-trigger"

vap=$(kdoc ValidatingAdmissionPolicy)
grep -q 'failurePolicy: Fail' <<<"$vap" || fail "the job guard is a safety gate: failurePolicy must be Fail"
grep -q "request.userInfo.username == 'system:serviceaccount:n8n-workflow:n8n-batch-trigger'" <<<"$vap" \
  || fail "the job guard must match the n8n-batch-trigger SA"
grep -q '^  namespace:' <<<"$vap" && fail "the VAP is cluster-scoped: no metadata.namespace (keep it out of base/)"
vapb=$(kdoc ValidatingAdmissionPolicyBinding)
grep -q -- '- Deny' <<<"$vapb" || fail "the job guard binding must Deny, not just Warn/Audit"

ns=$(kdoc Namespace)
grep -q 'pod-security.kubernetes.io/enforce: restricted' <<<"$ns" || fail "gpu-batch must enforce Pod Security restricted"
echo "RENDER-INVARIANTS-OK"
