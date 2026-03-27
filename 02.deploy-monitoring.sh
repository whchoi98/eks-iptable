#!/bin/bash
set -e

# 3개 클러스터에 모니터링 스택 배포
# - conntrack-monitor DaemonSet
# - kube-prometheus-stack (Helm)

set +eu; source ~/.bash_profile; set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLUSTERS=("ekscluster01-iptables" "ekscluster01-ipvs" "ekscluster01-nftables")

echo "============================================"
echo "  모니터링 스택 배포"
echo "============================================"

deploy_monitoring() {
  local cluster="$1"

  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  ▶ ${cluster} 모니터링 배포"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  kubectl config use-context "${cluster}"

  echo "  ▶ conntrack-monitor DaemonSet 배포..."
  kubectl apply -f "${SCRIPT_DIR}/manifests/conntrack-monitor-ds.yaml"
  echo "  ✅ conntrack-monitor 배포 완료"

  echo "  ▶ kube-prometheus-stack 배포..."
  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
  helm repo update

  helm upgrade --install prometheus prometheus-community/kube-prometheus-stack \
    --namespace monitoring --create-namespace \
    --values "${SCRIPT_DIR}/manifests/prometheus-stack/values.yaml" \
    --wait --timeout 10m

  echo "  ✅ Prometheus + Grafana 배포 완료"

  echo "  ▶ 상태 확인..."
  kubectl get pods -n conntrack-monitor -o wide
  kubectl get pods -n monitoring -o wide
}

for cluster in "${CLUSTERS[@]}"; do
  STATUS=$(aws eks describe-cluster --name "${cluster}" \
    --query 'cluster.status' --output text \
    --region ap-northeast-2 2>/dev/null || echo "NOT_FOUND")

  if [ "$STATUS" != "ACTIVE" ]; then
    echo "  ⚠️  ${cluster} 가 ACTIVE가 아닙니다 (${STATUS}). 건너뜁니다."
    continue
  fi

  aws eks update-kubeconfig --name "${cluster}" --region ap-northeast-2 --alias "${cluster}"
  deploy_monitoring "${cluster}"
done

echo ""
echo "============================================"
echo "  ✅ 모니터링 배포 완료"
echo "============================================"
echo ""
echo "  다음 단계: ./03.deploy-test-workload.sh"
echo "============================================"
