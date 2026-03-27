#!/bin/bash
set -e

# conntrack 부하 테스트 실행 및 결과 수집
# 사용법: ./04.run-conntrack-test.sh [클러스터명]

set +eu; source ~/.bash_profile; set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS_DIR="${SCRIPT_DIR}/results"
mkdir -p "${RESULTS_DIR}"

CLUSTERS=("ekscluster01-iptables" "ekscluster01-ipvs" "ekscluster01-nftables")
LOAD_LEVELS=(1000 5000 10000 50000)
DURATION="300"

echo "============================================"
echo "  conntrack 부하 테스트 실행"
echo "============================================"
echo "  부하 단계: ${LOAD_LEVELS[*]} connections"
echo "  각 단계: ${DURATION}초 (5분)"
echo ""

collect_conntrack_metrics() {
  local cluster="$1"
  local stage="$2"
  local output_file="${RESULTS_DIR}/${cluster}_stage${stage}_conntrack.json"

  echo "  ▶ conntrack 메트릭 수집..."
  kubectl logs -n conntrack-monitor -l app=conntrack-monitor \
    --since=60s --all-containers --timestamps 2>/dev/null \
    | grep -o '{.*}' > "${output_file}" || true

  local count=$(wc -l < "${output_file}")
  echo "  ✅ ${count} 레코드 수집 -> ${output_file}"
}

collect_kubeproxy_metrics() {
  local cluster="$1"
  local stage="$2"
  local output_file="${RESULTS_DIR}/${cluster}_stage${stage}_kubeproxy.txt"

  echo "  ▶ kube-proxy 메트릭 수집..."
  PROXY_POD=$(kubectl get pods -n kube-system -l k8s-app=kube-proxy \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

  if [ -n "$PROXY_POD" ]; then
    kubectl exec -n kube-system "${PROXY_POD}" -- \
      curl -s http://localhost:10249/metrics 2>/dev/null \
      | grep -E "kubeproxy_sync_proxy_rules|kubeproxy_network_programming" \
      > "${output_file}" || true
    echo "  ✅ kube-proxy 메트릭 -> ${output_file}"
  else
    echo "  ⚠️  kube-proxy Pod 접근 불가"
  fi
}

run_load_test() {
  local cluster="$1"
  local connections="$2"
  local stage="$3"
  local output_file="${RESULTS_DIR}/${cluster}_stage${stage}_fortio.json"

  echo ""
  echo "  ──────────────────────────────────────"
  echo "  Stage ${stage}: ${connections} concurrent connections"
  echo "  ──────────────────────────────────────"

  kubectl set env ds/conntrack-monitor -n conntrack-monitor COLLECT_INTERVAL=1 2>/dev/null || true

  FORTIO_POD=$(kubectl get pods -n conntrack-test -l app=fortio-client \
    -o jsonpath='{.items[0].metadata.name}')

  echo "  ▶ fortio 부하 시작 (${connections} conn, ${DURATION}s)..."

  kubectl exec -n conntrack-test "${FORTIO_POD}" -- \
    fortio load -c "${connections}" -t "${DURATION}s" -qps 0 \
    -json "${output_file}" \
    http://svc-001.conntrack-test.svc.cluster.local:80 \
    2>&1 | tail -5

  echo "  ✅ 부하 완료"

  collect_conntrack_metrics "${cluster}" "${stage}"
  collect_kubeproxy_metrics "${cluster}" "${stage}"

  kubectl cp "conntrack-test/${FORTIO_POD}:${output_file}" \
    "${output_file}" 2>/dev/null || true

  kubectl set env ds/conntrack-monitor -n conntrack-monitor COLLECT_INTERVAL=5 2>/dev/null || true

  echo "  ▶ 30초 쿨다운..."
  sleep 30
}

TARGET="${1:-all}"
if [ "$TARGET" = "all" ]; then
  TEST_CLUSTERS=("${CLUSTERS[@]}")
else
  TEST_CLUSTERS=("$TARGET")
fi

for cluster in "${TEST_CLUSTERS[@]}"; do
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  ▶ ${cluster} 부하 테스트"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  kubectl config use-context "${cluster}"

  STAGE=1
  for conns in "${LOAD_LEVELS[@]}"; do
    run_load_test "${cluster}" "${conns}" "${STAGE}"
    STAGE=$((STAGE + 1))
  done
done

echo ""
echo "============================================"
echo "  ✅ 부하 테스트 완료"
echo "============================================"
echo ""
echo "  결과 파일:"
ls -la "${RESULTS_DIR}/"
echo ""
echo "  다음 단계: 결과 분석 후 ./05.cleanup-clusters.sh"
echo "============================================"
