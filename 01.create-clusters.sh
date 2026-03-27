#!/bin/bash
set -e

# EKS kube-proxy 모드별 conntrack 분석 클러스터 3개 생성
# 사용법: ./01.create-clusters.sh [iptables|ipvs|nftables|all]

set +eu; source ~/.bash_profile; set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE="${SCRIPT_DIR}/templates/eksctl-cluster.yaml.tpl"
AWS_REGION="ap-northeast-2"

declare -A CLUSTER_NAMES=(
  [iptables]="ekscluster01-iptables"
  [ipvs]="ekscluster01-ipvs"
  [nftables]="ekscluster01-nftables"
)

declare -A NODEGROUP_NAMES=(
  [iptables]="ng-iptables"
  [ipvs]="ng-ipvs"
  [nftables]="ng-nftables"
)

declare -A PROXY_CONFIGS=(
  [iptables]=""
  [ipvs]="    configurationValues: '{\"mode\": \"ipvs\", \"ipvs\": {\"scheduler\": \"rr\"}}'"
  [nftables]="    configurationValues: '{\"mode\": \"nftables\"}'"
)

TARGET_MODE="${1:-all}"
if [ "$TARGET_MODE" = "all" ]; then
  MODES=("iptables" "ipvs" "nftables")
else
  if [[ ! "${CLUSTER_NAMES[$TARGET_MODE]+_}" ]]; then
    echo "❌ 알 수 없는 모드: $TARGET_MODE"
    echo "사용법: $0 [iptables|ipvs|nftables|all]"
    exit 1
  fi
  MODES=("$TARGET_MODE")
fi

echo "============================================"
echo "  EKS conntrack 분석 클러스터 생성"
echo "============================================"
echo "  대상 모드: ${MODES[*]}"
echo "  EKS 버전: 1.35"
echo "  노드: m6g.xlarge × 4 (private only)"
echo "  리전: ${AWS_REGION}"
echo ""

create_cluster() {
  local mode="$1"
  local cluster_name="${CLUSTER_NAMES[$mode]}"
  local nodegroup_name="${NODEGROUP_NAMES[$mode]}"
  local proxy_config="${PROXY_CONFIGS[$mode]}"

  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  ▶ 클러스터 생성: ${cluster_name} (mode: ${mode})"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  EXISTING=$(aws eks describe-cluster --name "${cluster_name}" \
    --query 'cluster.status' --output text \
    --region "${AWS_REGION}" 2>/dev/null || echo "NOT_FOUND")

  if [ "$EXISTING" = "ACTIVE" ]; then
    echo "  ⚠️  클러스터 '${cluster_name}'이(가) 이미 존재합니다. 건너뜁니다."
    aws eks update-kubeconfig --name "${cluster_name}" --region "${AWS_REGION}" --alias "${cluster_name}"
    return 0
  fi

  local config_file="${SCRIPT_DIR}/${cluster_name}.yaml"
  export CLUSTER_NAME="${cluster_name}"
  export PROXY_MODE="${mode}"
  export NODEGROUP_NAME="${nodegroup_name}"
  export PROXY_CONFIG_VALUES="${proxy_config}"

  envsubst < "${TEMPLATE}" > "${config_file}"
  echo "  ✅ 설정 파일 생성: ${config_file}"

  echo "  ▶ dry-run 검증..."
  if ! eksctl create cluster --config-file="${config_file}" --dry-run > /dev/null 2>&1; then
    echo "  ❌ dry-run 실패:"
    eksctl create cluster --config-file="${config_file}" --dry-run 2>&1 | tail -10
    return 1
  fi
  echo "  ✅ dry-run 통과"

  echo "  ▶ 클러스터 생성 시작... (예상 15-25분)"
  echo "  시작: $(date '+%Y-%m-%d %H:%M:%S')"
  eksctl create cluster --config-file="${config_file}"
  echo "  완료: $(date '+%Y-%m-%d %H:%M:%S')"

  aws eks update-kubeconfig --name "${cluster_name}" --region "${AWS_REGION}" --alias "${cluster_name}"
  echo "  ✅ ${cluster_name} 생성 완료"
  kubectl --context "${cluster_name}" get nodes -o wide
}

echo ""
read -p "계속 진행하시겠습니까? (yes/no): " CONFIRM
if [ "$CONFIRM" != "yes" ]; then
  echo "취소되었습니다."
  exit 0
fi

for mode in "${MODES[@]}"; do
  create_cluster "$mode"
done

echo ""
echo "============================================"
echo "  ✅ 클러스터 생성 완료"
echo "============================================"
echo ""
for mode in "${MODES[@]}"; do
  echo "  ${CLUSTER_NAMES[$mode]} (${mode})"
done
echo ""
echo "  다음 단계: ./02.deploy-monitoring.sh"
echo "============================================"
