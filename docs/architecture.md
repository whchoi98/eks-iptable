# Architecture

## Overview

EKS kube-proxy 모드별(iptables/ipvs/nftables) conntrack table sync 시간 영향도를 비교 분석하는 테스트 환경.

## Components

### 클러스터 인프라
- **eksctl**: 3개 EKS 클러스터를 동일 VPC에 생성, kube-proxy 모드만 다르게 구성
- **VPC**: vpc-0151a6dcd10c1c738, private subnet 2개 (ap-northeast-2a/2b)
- **노드**: m6g.xlarge × 4 (Graviton ARM64), AL2023

### 모니터링 스택
- **conntrack-monitor**: privileged DaemonSet, 각 노드에서 conntrack 통계를 5초 간격으로 JSON 수집
- **kube-prometheus-stack**: Prometheus (메트릭 수집) + Grafana (시각화)
- **kube-proxy 메트릭**: 노드 10249 포트, curl debug pod으로 수집

### 테스트 워크로드
- **Nginx Backend**: 180 replicas, 100개 ClusterIP Service의 백엔드
- **fortio**: 부하 생성기, 1000~50000 concurrent connections

## Data Flow

```
fortio → ClusterIP Service (svc-001~100) → kube-proxy 룰 → Nginx Pod
                                              ↓
                                    conntrack table 엔트리 생성
                                              ↓
                                    conntrack-monitor DaemonSet 수집
                                              ↓
                                    results/ 디렉토리에 JSON 저장
```

## Key Design Decisions

- 동일 VPC에 3개 클러스터를 배치하여 네트워크 조건 통일
- private subnet only로 운영 환경과 유사한 조건 재현
- kube-proxy 메트릭은 distroless 이미지 제약으로 curl debug pod 사용
- 노드당 58 Pod 제한(ENI)으로 nginx replicas를 180으로 조정
