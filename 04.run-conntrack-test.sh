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
AWS_REGION="ap-northeast-2"

declare -A NODEGROUP_NAMES=(
  [ekscluster01-iptables]="ng-iptables"
  [ekscluster01-ipvs]="ng-ipvs"
  [ekscluster01-nftables]="ng-nftables"
)

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

  echo "  ▶ kube-proxy 메트릭 수집 (전체 노드)..."
  local proxy_pods
  proxy_pods=$(kubectl get pods -n kube-system -l k8s-app=kube-proxy \
    -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")

  > "${output_file}"
  for pod in ${proxy_pods}; do
    local node
    node=$(kubectl get pod -n kube-system "${pod}" -o jsonpath='{.spec.nodeName}' 2>/dev/null)
    echo "# node=${node} pod=${pod}" >> "${output_file}"
    kubectl exec -n kube-system "${pod}" -- \
      curl -s http://localhost:10249/metrics 2>/dev/null \
      | grep -E "kubeproxy_sync_proxy_rules|kubeproxy_network_programming|kubeproxy_sync_proxy_rules_iptables_total|kubeproxy_sync_proxy_rules_last_queued_timestamp|kubeproxy_sync_proxy_rules_no_local_endpoints" \
      >> "${output_file}" 2>/dev/null || true
    echo "" >> "${output_file}"
  done

  if [ -s "${output_file}" ]; then
    echo "  ✅ kube-proxy 메트릭 (${proxy_pods// / }) -> ${output_file}"
  else
    echo "  ⚠️  kube-proxy Pod 접근 불가"
  fi
}

# ──────────────────────────────────────────────────
# 노드 스케일아웃 테스트: kube-proxy 초기 sync 시간 측정
# ──────────────────────────────────────────────────
run_scaleout_test() {
  local cluster="$1"
  local nodegroup="${NODEGROUP_NAMES[$cluster]}"
  local output_file="${RESULTS_DIR}/${cluster}_scaleout_sync.txt"
  local metrics_before="${RESULTS_DIR}/${cluster}_scaleout_before.txt"
  local metrics_after="${RESULTS_DIR}/${cluster}_scaleout_after.txt"

  echo ""
  echo "  ══════════════════════════════════════"
  echo "  노드 스케일아웃 테스트: ${cluster}"
  echo "  ══════════════════════════════════════"

  # 기존 노드 목록 저장
  local existing_nodes
  existing_nodes=$(kubectl get nodes -o jsonpath='{.items[*].metadata.name}')
  local existing_count
  existing_count=$(echo "${existing_nodes}" | wc -w)
  echo "  기존 노드 수: ${existing_count}"

  # 기존 kube-proxy 메트릭 수집 (baseline)
  echo "  ▶ baseline kube-proxy 메트릭 수집..."
  collect_kubeproxy_metrics "${cluster}" "scaleout_before"

  # 노드 1개 추가 (4 → 5)
  local new_size=$((existing_count + 1))
  echo "  ▶ 노드그룹 스케일아웃: ${existing_count} → ${new_size}"
  local scale_start
  scale_start=$(date +%s)

  aws eks update-nodegroup-config \
    --cluster-name "${cluster}" \
    --nodegroup-name "${nodegroup}" \
    --scaling-config "minSize=${new_size},maxSize=${new_size},desiredSize=${new_size}" \
    --region "${AWS_REGION}" > /dev/null 2>&1

  # 새 노드 Ready 대기
  echo "  ▶ 새 노드 Ready 대기..."
  local new_node=""
  local wait_count=0
  while [ -z "${new_node}" ] && [ ${wait_count} -lt 60 ]; do
    sleep 10
    wait_count=$((wait_count + 1))
    local current_nodes
    current_nodes=$(kubectl get nodes -o jsonpath='{.items[*].metadata.name}')
    for node in ${current_nodes}; do
      if ! echo "${existing_nodes}" | grep -q "${node}"; then
        local status
        status=$(kubectl get node "${node}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
        if [ "${status}" = "True" ]; then
          new_node="${node}"
          break
        fi
      fi
    done
    echo "    대기 중... (${wait_count}0s)"
  done

  if [ -z "${new_node}" ]; then
    echo "  ❌ 새 노드 감지 실패 (timeout)"
    return 1
  fi

  local node_ready_time
  node_ready_time=$(date +%s)
  local node_join_duration=$((node_ready_time - scale_start))
  echo "  ✅ 새 노드 Ready: ${new_node} (${node_join_duration}s)"

  # 새 노드의 kube-proxy Pod 찾기
  echo "  ▶ 새 노드의 kube-proxy Pod 대기..."
  local new_proxy_pod=""
  local proxy_wait=0
  while [ -z "${new_proxy_pod}" ] && [ ${proxy_wait} -lt 30 ]; do
    sleep 5
    proxy_wait=$((proxy_wait + 1))
    new_proxy_pod=$(kubectl get pods -n kube-system -l k8s-app=kube-proxy \
      --field-selector "spec.nodeName=${new_node}" \
      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
  done

  if [ -z "${new_proxy_pod}" ]; then
    echo "  ❌ 새 노드의 kube-proxy Pod 감지 실패"
    return 1
  fi
  echo "  ✅ kube-proxy Pod: ${new_proxy_pod}"

  # kube-proxy Ready 대기 후 메트릭 수집
  echo "  ▶ kube-proxy 메트릭 수집 대기 (초기 sync 완료 후)..."
  sleep 30

  # 새 노드 kube-proxy 메트릭 수집
  echo "  ▶ 새 노드 kube-proxy 메트릭 수집..."
  > "${output_file}"
  echo "# 노드 스케일아웃 테스트 결과" >> "${output_file}"
  echo "# cluster: ${cluster}" >> "${output_file}"
  echo "# proxy_mode: ${cluster##*-}" >> "${output_file}"
  echo "# scale_start_epoch: ${scale_start}" >> "${output_file}"
  echo "# node_ready_epoch: ${node_ready_time}" >> "${output_file}"
  echo "# node_join_duration_sec: ${node_join_duration}" >> "${output_file}"
  echo "# new_node: ${new_node}" >> "${output_file}"
  echo "# new_proxy_pod: ${new_proxy_pod}" >> "${output_file}"
  echo "# existing_services: $(kubectl get svc -n conntrack-test --no-headers | wc -l)" >> "${output_file}"
  echo "# existing_endpoints: $(kubectl get endpointslices -n conntrack-test --no-headers | wc -l)" >> "${output_file}"
  echo "" >> "${output_file}"

  # 새 노드 kube-proxy의 sync duration histogram
  echo "## new_node kube-proxy metrics" >> "${output_file}"
  kubectl exec -n kube-system "${new_proxy_pod}" -- \
    curl -s http://localhost:10249/metrics 2>/dev/null \
    | grep -E "kubeproxy_sync_proxy_rules_duration_seconds|kubeproxy_sync_proxy_rules_iptables_total|kubeproxy_sync_proxy_rules_last_queued_timestamp|kubeproxy_sync_proxy_rules_no_local_endpoints|kubeproxy_network_programming" \
    >> "${output_file}" 2>/dev/null || true

  # sync duration에서 최대값 추출 (초기 full sync)
  local sync_sum sync_count
  sync_sum=$(grep 'kubeproxy_sync_proxy_rules_duration_seconds_sum' "${output_file}" | head -1 | awk '{print $2}')
  sync_count=$(grep 'kubeproxy_sync_proxy_rules_duration_seconds_count' "${output_file}" | head -1 | awk '{print $2}')

  echo "" >> "${output_file}"
  echo "# sync_duration_sum: ${sync_sum:-N/A}" >> "${output_file}"
  echo "# sync_count: ${sync_count:-N/A}" >> "${output_file}"

  echo "  ✅ 결과 -> ${output_file}"
  echo ""
  echo "  ┌─────────────────────────────────────┐"
  echo "  │ 스케일아웃 테스트 결과 요약          │"
  echo "  ├─────────────────────────────────────┤"
  echo "  │ 클러스터: ${cluster}"
  echo "  │ 노드 조인 시간: ${node_join_duration}s"
  echo "  │ sync_duration_sum: ${sync_sum:-N/A}s"
  echo "  │ sync_count: ${sync_count:-N/A}"
  echo "  └─────────────────────────────────────┘"

  # 전체 노드 kube-proxy 메트릭 수집 (after)
  collect_kubeproxy_metrics "${cluster}" "scaleout_after"

  # 노드 원복 (5 → 4)
  echo "  ▶ 노드그룹 원복: ${new_size} → ${existing_count}"
  aws eks update-nodegroup-config \
    --cluster-name "${cluster}" \
    --nodegroup-name "${nodegroup}" \
    --scaling-config "minSize=${existing_count},maxSize=${existing_count},desiredSize=${existing_count}" \
    --region "${AWS_REGION}" > /dev/null 2>&1

  echo "  ✅ 노드 원복 요청 완료 (백그라운드 축소)"
  echo "  ▶ 60초 쿨다운..."
  sleep 60
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
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ▶ 노드 스케일아웃 테스트 (kube-proxy 초기 sync 시간)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Service/EndpointSlice가 다수 존재하는 상태에서"
echo "  새 노드의 kube-proxy가 초기 sync를 완료하는 시간을"
echo "  모드별(iptables/ipvs/nftables)로 비교합니다."
echo ""

for cluster in "${TEST_CLUSTERS[@]}"; do
  kubectl config use-context "${cluster}"
  run_scaleout_test "${cluster}" || echo "  ⚠️  ${cluster} 스케일아웃 테스트 실패, 계속 진행"
done

# 스케일아웃 결과 비교 출력
echo ""
echo "============================================"
echo "  노드 스케일아웃 kube-proxy sync 비교"
echo "============================================"
printf "  %-25s %-15s %-15s %-10s\n" "Cluster" "JoinTime(s)" "SyncSum(s)" "SyncCount"
printf "  %-25s %-15s %-15s %-10s\n" "-------------------------" "---------------" "---------------" "----------"
for cluster in "${TEST_CLUSTERS[@]}"; do
  local_file="${RESULTS_DIR}/${cluster}_scaleout_sync.txt"
  if [ -f "${local_file}" ]; then
    join=$(grep "node_join_duration_sec" "${local_file}" | awk -F': ' '{print $2}')
    ssum=$(grep "sync_duration_sum" "${local_file}" | tail -1 | awk -F': ' '{print $2}')
    scnt=$(grep "sync_count" "${local_file}" | tail -1 | awk -F': ' '{print $2}')
    printf "  %-25s %-15s %-15s %-10s\n" "${cluster}" "${join:-N/A}" "${ssum:-N/A}" "${scnt:-N/A}"
  else
    printf "  %-25s %-15s %-15s %-10s\n" "${cluster}" "N/A" "N/A" "N/A"
  fi
done
echo ""

echo ""
echo "============================================"
echo "  ✅ 전체 테스트 완료"
echo "============================================"
echo ""
echo "  결과 파일:"
ls -la "${RESULTS_DIR}/"
echo ""
echo "  다음 단계: 결과 분석 후 ./05.cleanup-clusters.sh"
echo "============================================"
