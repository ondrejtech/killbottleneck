#!/usr/bin/env bash
# Stáhne zálohy z PVC kb-backups v clusteru do lokální složky (výchozí ./custom-backup).
# Stahuje jen soubory, které ještě lokálně nejsou. Použití: ./k8s/pull-backups.sh [cílová-složka]
set -euo pipefail
NS=killbottleneck
DEST="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/custom-backup}"
POD=kb-backup-pull
mkdir -p "$DEST"; chmod 700 "$DEST"
trap 'kubectl -n $NS delete pod $POD --ignore-not-found --wait=false >/dev/null 2>&1' EXIT
kubectl -n $NS delete pod $POD --ignore-not-found >/dev/null 2>&1 || true
kubectl -n $NS run $POD --image=busybox --restart=Never --overrides='{"spec":{"nodeSelector":{"kubernetes.io/hostname":"vps1"},"containers":[{"name":"'$POD'","image":"busybox","command":["sleep","600"],"volumeMounts":[{"name":"b","mountPath":"/backups"}]}],"volumes":[{"name":"b","persistentVolumeClaim":{"claimName":"kb-backups"}}]}}' >/dev/null
kubectl -n $NS wait --for=condition=Ready pod/$POD --timeout=120s >/dev/null
n=0
for f in $(kubectl -n $NS exec $POD -- sh -c 'ls /backups | grep "^kb-backup-.*\.tgz$"' || true); do
  if [ ! -s "$DEST/$f" ]; then
    kubectl -n $NS exec $POD -- cat "/backups/$f" > "$DEST/$f.part" && mv "$DEST/$f.part" "$DEST/$f"
    chmod 600 "$DEST/$f"; echo "stazeno: $f"; n=$((n+1))
  fi
done
echo "Hotovo, nove soubory: $n, slozka: $DEST"
