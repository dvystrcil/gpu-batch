# gpu-batch

Deploy repo for the **GPU batch lane** on the GTX 970 (`homelab/role=small-model-gpu`, k8s-node-01 since homelab#2119) ([homelab#1935](https://github.com/dvystrcil/homelab/issues/1935); design in [`homelab/architecture/gpu-batch-lane.md`](https://github.com/dvystrcil/homelab/blob/main/architecture/gpu-batch-lane.md)). Synced by Argo CD (`argocd-projects/gpu-batch`). **Nothing here runs by itself.**

| Object | Purpose |
|---|---|
| `Namespace gpu-batch` | ambient mesh |
| `PersistentVolume/PVC gpu-batch-work` | static NFS `192.168.86.176:/mnt/pool/media/gpu-batch`, the share the laptop mounts at `/mnt/nfs/media`. `soft` mount, so a scrub stall becomes a reported failure, not a silent hang |
| `CronJob blender-render` | the **Job template**: suspended, never scheduled. `homelab/bin/gpu-batch-submit.py` creates Jobs from its `jobTemplate`. All the bounds live here |
| `ServiceAccount gpu-batch-runner` | the only grant is `get` on one Obico Secret (in `dvystrcil/obico`) |
| `InfisicalSecret gpu-batch-harbor-pull` | image pull |

The image tag in `overlays/kustomization.yaml` is bumped by a PR from `gpu-batch-docker`'s release workflow. argocd-image-updater can't see CronJobs (homelab#951).

`tests/test-render.sh` pins the decisions (template suspended, the GPU role label, `backoffLimit: 0`, deadline equals `GPU_BATCH_DEADLINE_S`, 500m CPU with no CPU limit, memory limit, 5 GPU units, guard and notifier env, soft NFS). Change a value and its test together.

Licensed [MIT](LICENSE).

<!-- homelab#1225 bypass test, 2026-11-07 (second run, the App identity verified first). This line changes nothing. -->
