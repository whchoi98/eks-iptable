# 테스트 결과 요약

> 테스트 일시: 2026-03-28 | EKS 1.35, kube-proxy v1.35.2

## Full Sync (초기 전체 룰 적용)

| 모드 | 평균 1회 소요 |
|------|-------------|
| iptables | 29.55s |
| ipvs | ~1-2s (추정) |
| nftables | 1.56s |

## Regular Sync (증분 동기화)

| 모드 | 평균 Sync | 횟수 |
|------|----------|------|
| iptables | 0.737s | 201회 |
| ipvs | 0.232s | 1,613회 |
| nftables | 0.260s | 203회 |

## Fortio 부하 테스트 (1,000 conn / 300s)

| 지표 | iptables | ipvs | nftables |
|------|---------|------|---------|
| QPS | 39,036 | 31,702 | 37,558 |
| P50 | 25ms | 32ms | 27ms |
| P99 | 121ms | 170ms | 202ms |

## Fortio 부하 테스트 (5,000 conn / 300s)

| 지표 | iptables | ipvs | nftables |
|------|---------|------|---------|
| QPS | 39,419 | 31,891 | 37,375 |
| P99 | 491ms | 400ms | 391ms |
| P99.9 | 593ms | 497ms | 492ms |

## 노드 스케일아웃

| 단계 | iptables | ipvs | nftables |
|------|---------|------|---------|
| 노드 Ready | 44s | 76s | 44s |
| kube-proxy 초기 sync | ~29.5s | ~1-2s | ~1.6s |
| 총 서비스 가용 시간 | ~73.5s | ~78s | ~45.6s |

## 권장 사항

1. 오토스케일링 빈번한 환경 → nftables 또는 ipvs
2. 대규모 Service (500+) → ipvs 또는 nftables 필수
3. 안정성 우선 → ipvs
4. 최신 기능 + 최고 성능 → nftables
