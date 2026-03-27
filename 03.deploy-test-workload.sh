#!/bin/bash
set -e

# 3개 클러스터에 테스트 워크로드 배포
# - Nginx backend (200 replicas)
# - 100개 ClusterIP Service
# - fortio 부하 생성기

set +eu; source ~/.bash_profile; set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLUSTERS=("ekscluster01-iptables" "ekscluster01-ipvs" "ekscluster01-nftables")

echo "============================================"
echo "  테스트 워크로드 배포"
echo "============================================"

deploy_workload() {
  local cluster="$1"

  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  ▶ ${cluster} 워크로드 배포"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  kubectl config use-context "${cluster}"

  echo "  ▶ Nginx backend 배포 (200 replicas)..."
  kubectl apply -f "${SCRIPT_DIR}/manifests/test-services.yaml"

  echo "  ▶ ClusterIP Service 100개 생성..."
  for i in $(seq -w 1 100); do
    cat <<EOF | kubectl apply -f - 2>/dev/null
apiVersion: v1
kind: Service
metadata:
  name: svc-${i}
  namespace: conntrack-test
spec:
  type: ClusterIP
  selector:
    app: nginx-backend
  ports:
    - port: 80
      targetPort: 80
EOF
  done
  echo "  ✅ Service 100개 생성 완료"

  echo "  ▶ fortio 부하 생성기 배포..."
  kubectl apply -f "${SCRIPT_DIR}/manifests/fortio-loadgen.yaml"

  echo "  ▶ Pod Ready 대기..."
  kubectl wait --for=condition=Ready pod -l app=nginx-backend \
    -n conntrack-test --timeout=300s 2>/dev/null || true
  kubectl wait --for=condition=Ready pod -l app=fortio-client \
    -n conntrack-test --timeout=120s

  SVC_COUNT=$(kubectl get svc -n conntrack-test --no-headers | wc -l)
  POD_COUNT=$(kubectl get pods -n conntrack-test --no-headers | grep Running | wc -l)
  echo "  ✅ 배포 완료: Service=${SVC_COUNT}, Running Pods=${POD_COUNT}"
}

for cluster in "${CLUSTERS[@]}"; do
  STATUS=$(aws eks describe-cluster --name "${cluster}" \
    --query 'cluster.status' --output text \
    --region ap-northeast-2 2>/dev/null || echo "NOT_FOUND")

  if [ "$STATUS" != "ACTIVE" ]; then
    echo "  ⚠️  ${cluster} 건너뜀 (${STATUS})"
    continue
  fi

  aws eks update-kubeconfig --name "${cluster}" --region ap-northeast-2 --alias "${cluster}"
  deploy_workload "${cluster}"
done

echo ""
echo "============================================"
echo "  ✅ 테스트 워크로드 배포 완료"
echo "============================================"
echo ""
echo "  다음 단계: ./04.run-conntrack-test.sh"
echo "============================================"
