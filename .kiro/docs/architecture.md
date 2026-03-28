# 아키텍처

## 개요

EKS kube-proxy 모드별(iptables/ipvs/nftables) conntrack table sync 시간 영향도를 비교 분석하는 테스트 환경.

## 클러스터 인프라

```
VPC: vpc-0151a6dcd10c1c738 (10.11.0.0/16)
│
├── ekscluster01-iptables  (EKS 1.35, kube-proxy: iptables)
│   └── ng-iptables: m6g.xlarge × 4
│
├── ekscluster01-ipvs      (EKS 1.35, kube-proxy: ipvs)
│   └── ng-ipvs: m6g.xlarge × 4
│
└── ekscluster01-nftables  (EKS 1.35, kube-proxy: nftables)
    └── ng-nftables: m6g.xlarge × 4
```

- Private subnet 2개 (ap-northeast-2a/2b)
- API Endpoint: private only
- 노드: AL2023, kernel 6.12, containerd 2.2.1, ARM64

## 모니터링 스택

- conntrack-monitor: privileged DaemonSet, 5초 간격 JSON 수집
- kube-prometheus-stack: Prometheus + Grafana (Helm)
- kube-proxy 메트릭: 노드 10249 포트, curl debug pod으로 수집

## 테스트 워크로드

- Nginx Backend: 180 replicas, 100개 ClusterIP Service
- fortio: 1000~50000 concurrent connections

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

## Add-on 구성 (EKS 1.35)

| Add-on | 버전 |
|--------|------|
| vpc-cni | v1.21.1-eksbuild.5 |
| coredns | v1.13.2-eksbuild.3 |
| kube-proxy | v1.35.2-eksbuild.4 |
| aws-ebs-csi-driver | v1.57.1-eksbuild.1 |
| eks-pod-identity-agent | v1.3.10-eksbuild.2 |
| metrics-server | v0.8.1-eksbuild.4 |
| amazon-cloudwatch-observability | v5.2.3-eksbuild.1 |

## 비용 예측

| 항목 | 단가 | 수량 | 시간당 비용 |
|------|------|------|-----------|
| EKS Control Plane | $0.10/hr | 3 | $0.30 |
| m6g.xlarge | $0.154/hr | 12 | $1.848 |
| 합계 | | | $2.148/hr |
