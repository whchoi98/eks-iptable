#!/bin/bash
set -e

# 3개 conntrack 분석 클러스터 삭제
# 사용법: ./05.cleanup-clusters.sh [iptables|ipvs|nftables|all]

set +eu; source ~/.bash_profile; set -e

CLUSTERS=("ekscluster01-iptables" "ekscluster01-ipvs" "ekscluster01-nftables")
TARGET="${1:-all}"
AWS_REGION="ap-northeast-2"

echo "============================================"
echo "  EKS conntrack 분석 클러스터 삭제"
echo "============================================"
echo ""

if [ "$TARGET" = "all" ]; then
  DELETE_CLUSTERS=("${CLUSTERS[@]}")
else
  DELETE_CLUSTERS=("ekscluster01-${TARGET}")
fi

echo "  삭제 대상:"
for c in "${DELETE_CLUSTERS[@]}"; do
  echo "    - ${c}"
done
echo ""
read -p "  정말 삭제하시겠습니까? (yes/no): " CONFIRM
if [ "$CONFIRM" != "yes" ]; then
  echo "  취소되었습니다."
  exit 0
fi

for cluster in "${DELETE_CLUSTERS[@]}"; do
  echo ""
  echo "  ▶ ${cluster} 삭제 중..."

  EXISTING=$(aws eks describe-cluster --name "${cluster}" \
    --query 'cluster.status' --output text \
    --region "${AWS_REGION}" 2>/dev/null || echo "NOT_FOUND")

  if [ "$EXISTING" = "NOT_FOUND" ]; then
    echo "  ⚠️  ${cluster} 없음, 건너뜁니다."
    continue
  fi

  eksctl delete cluster --name "${cluster}" --region "${AWS_REGION}" --wait
  echo "  ✅ ${cluster} 삭제 완료"

  rm -f "$(dirname "$0")/${cluster}.yaml"

  kubectl config delete-context "${cluster}" 2>/dev/null || true
done

echo ""
echo "============================================"
echo "  ✅ 클러스터 삭제 완료"
echo "============================================"
