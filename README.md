# EKS kube-proxy Mode Comparison: iptables vs ipvs vs nftables

> **Language / 언어 선택**
>
> [한국어](#한국어) | [English](#english)

---

# 한국어

EKS 1.35 환경에서 kube-proxy 모드별(iptables / ipvs / nftables) **conntrack table sync 시간**, **패킷 처리 성능**, **노드 스케일아웃 영향도**를 비교 분석하는 프로젝트입니다.

## 배경

EKS에서 오토스케일링으로 노드가 추가될 때, kube-proxy가 기존 모든 Service/EndpointSlice 룰을 초기화(Full Sync)하는 과정에서 **수십~수백 초의 지연**이 발생할 수 있습니다. 이 프로젝트는 3가지 kube-proxy 모드를 동일한 조건에서 비교하여 최적의 모드를 선정하기 위한 근거를 제공합니다.

## 주요 결과

### 초기 Full Sync 소요 시간 (101 Service 기준)

```
iptables  ████████████████████████████████████████  29.55s
ipvs      ██                                        ~1-2s (추정)
nftables  ██                                        1.56s

→ iptables는 ipvs/nftables 대비 15~19배 느림
```

> **운영 환경 추정**: Service 500개 → ~150s, Service 1000개 → ~300s (iptables 선형 증가)

### Fortio 부하 테스트 결과

**1,000 concurrent connections / 300s**

| 지표 | iptables | ipvs | nftables |
|------|---------|------|---------|
| QPS | **39,036** | 31,702 | 37,558 |
| P50 | **25ms** | 32ms | 27ms |
| P99 | **121ms** | 170ms | 202ms |

**5,000 concurrent connections / 300s**

| 지표 | iptables | ipvs | nftables |
|------|---------|------|---------|
| QPS | **39,419** | 31,891 | 37,375 |
| P50 | 153ms | 190ms | **150ms** |
| P99 | 491ms | 400ms | **391ms** |

### 노드 스케일아웃 총 시간

| 단계 | iptables | ipvs | nftables |
|------|---------|------|---------|
| 노드 Ready | 44s | 76s | 44s |
| kube-proxy 초기 sync | **29.5s** | **~1-2s** | **1.6s** |
| **총 서비스 가용 시간** | **~73.5s** | **~78s** | **~45.6s** |

### 모드별 특성 요약

| 특성 | iptables | ipvs | nftables |
|------|---------|------|---------|
| 초기 Full Sync | 29.55s | ~1-2s | 1.56s |
| Regular Sync 평균 | 0.737s | 0.232s | 0.260s |
| iptables NAT 룰 수 | 54,214 | N/A (해시) | N/A (nft set) |
| QPS (1K conn) | 39,036 | 31,702 | 37,558 |
| P99 (5K conn) | 491ms | 400ms | 391ms |
| 스케일아웃 총 시간 | ~73.5s | ~78s | ~45.6s |
| 성숙도 | 가장 검증됨 | 안정적 | 최신 (EKS 1.31+) |

> 상세 분석은 [`results/analysis-report.md`](results/analysis-report.md)를 참고하세요.

## 아키텍처

```
                        ┌─────────────────────────────────────────────┐
                        │              동일 VPC (private subnet)       │
                        │                                             │
┌───────────────┐  ┌────┴────────────┐  ┌──────────────────┐  ┌──────┴───────────┐
│ ekscluster01  │  │ ekscluster01    │  │ ekscluster01     │  │  VPC Endpoints   │
│ -iptables     │  │ -ipvs           │  │ -nftables        │  │  (ECR,STS,EC2..) │
│               │  │                 │  │                  │  └──────────────────┘
│ kube-proxy:   │  │ kube-proxy:     │  │ kube-proxy:      │
│   iptables    │  │   ipvs (rr)     │  │   nftables       │
│ m6g.xlarge×4  │  │ m6g.xlarge×4    │  │ m6g.xlarge×4     │
└───────┬───────┘  └───────┬─────────┘  └────────┬─────────┘
        └──────────────────┼──────────────────────┘
              ┌────────────┴────────────┐
              │    각 클러스터 공통 구성    │
              │  - Nginx 180 replicas   │
              │  - ClusterIP Svc × 101  │
              │  - fortio load gen      │
              │  - conntrack-monitor DS │
              │  - Prometheus + Grafana │
              └─────────────────────────┘
```

## 테스트 환경

| 항목 | 값 |
|-----|---|
| EKS 버전 | 1.35.2 |
| kube-proxy | v1.35.2-eksbuild.4 |
| 노드 | m6g.xlarge × 4 (Graviton ARM64, 4vCPU/16GiB) |
| AMI | Amazon Linux 2023 (kernel 6.12) |
| 네트워크 | private subnet only, NAT Gateway |
| Services | 101개 (ClusterIP) |
| EndpointSlices | 201개 |
| Backend Pods | 180개 (Nginx) |
| 부하 도구 | fortio v1.75.1 |
| 모니터링 | kube-prometheus-stack (Helm) |
| 리전 | ap-northeast-2 |

## 사전 요구사항

- AWS CLI v2 + 적절한 IAM 권한
- eksctl v0.200+
- kubectl v1.35+
- Helm v3.x
- bash 4.x+

## 빠른 시작

### 1. 클러스터 생성

```bash
# 3개 클러스터 모두 생성 (~45-75분)
./01.create-clusters.sh all

# 또는 개별 생성
./01.create-clusters.sh iptables
./01.create-clusters.sh ipvs
./01.create-clusters.sh nftables
```

### 2. 모니터링 배포

```bash
./02.deploy-monitoring.sh
```

### 3. 테스트 워크로드 배포

```bash
./03.deploy-test-workload.sh
```

### 4. 부하 테스트 + 메트릭 수집

```bash
# 전체 클러스터 (부하 4단계 + 노드 스케일아웃 테스트)
./04.run-conntrack-test.sh

# 특정 클러스터만
./04.run-conntrack-test.sh ekscluster01-iptables
```

### 5. 정리

```bash
./05.cleanup-clusters.sh
```

## 프로젝트 구조

```
eks-iptable/
├── 01.create-clusters.sh        # EKS 클러스터 3개 생성 (eksctl)
├── 02.deploy-monitoring.sh      # 모니터링 스택 배포
├── 03.deploy-test-workload.sh   # Nginx + Service 100개 + fortio 배포
├── 04.run-conntrack-test.sh     # 부하 테스트 + 메트릭 수집 + 노드 스케일아웃 테스트
├── 05.cleanup-clusters.sh       # 전체 리소스 정리
│
├── templates/
│   └── eksctl-cluster.yaml.tpl  # eksctl 클러스터 템플릿 (envsubst)
│
├── manifests/
│   ├── conntrack-monitor-ds.yaml        # conntrack 통계 수집 DaemonSet
│   ├── prometheus-stack/values.yaml     # kube-prometheus-stack Helm values
│   ├── test-services.yaml               # Nginx Deployment (180 replicas)
│   └── fortio-loadgen.yaml              # fortio 부하 생성기
│
├── ekscluster01-iptables.yaml   # iptables 클러스터 eksctl 설정
├── ekscluster01-ipvs.yaml       # ipvs 클러스터 eksctl 설정
├── ekscluster01-nftables.yaml   # nftables 클러스터 eksctl 설정
│
├── results/                     # 테스트 결과
│   ├── analysis-report.md       # 종합 분석 보고서
│   ├── *_conntrack.json         # conntrack 메트릭
│   ├── *_kubeproxy.txt          # kube-proxy sync duration 메트릭
│   ├── *_kubeproxy_full.txt     # 전체 노드 kube-proxy 메트릭
│   └── *_scaleout_sync.txt      # 노드 스케일아웃 sync 결과
│
├── docs/
│   ├── architecture.md          # 아키텍처 문서
│   ├── decisions/               # ADR (Architecture Decision Records)
│   └── runbooks/                # 운영 Runbook
│
├── CLAUDE.md                    # 프로젝트 컨텍스트
└── README.md
```

## 수집 메트릭

### kube-proxy (노드 :10249/metrics)

| 메트릭 | 설명 | 해당 모드 |
|-------|------|---------|
| `kubeproxy_sync_proxy_rules_duration_seconds` | 증분 sync 소요 시간 | 전체 |
| `kubeproxy_sync_full_proxy_rules_duration_seconds` | full sync 소요 시간 | iptables, nftables |
| `kubeproxy_sync_proxy_rules_iptables_total` | iptables 룰 총 개수 | iptables |
| `kubeproxy_network_programming_duration_seconds` | 네트워크 프로그래밍 지연 | 전체 |

### conntrack (DaemonSet 수집)

| 메트릭 | 설명 |
|-------|------|
| `nf_conntrack_count` | 현재 conntrack 엔트리 수 |
| `nf_conntrack_max` | conntrack 테이블 최대 크기 |
| `conntrack -S` insert/insert_failed/drop | conntrack 통계 |

### fortio

| 메트릭 | 설명 |
|-------|------|
| QPS | 초당 요청 수 |
| P50 / P90 / P99 / P99.9 | 응답 레이턴시 백분위 |
| Code 200 비율 | 성공률 |

## 권장 사항

| 환경 | 권장 모드 | 이유 |
|------|---------|------|
| 오토스케일링 빈번 | **nftables** 또는 **ipvs** | iptables 초기 sync가 Service 수에 선형 비례 증가 |
| 대규모 Service (500+) | **ipvs** 또는 **nftables** | iptables O(n) 순차 탐색 → 패킷 처리 성능 저하 |
| 안정성 우선 | **ipvs** | 오래 검증된 대안, P99 tail latency 안정 |
| 최신 기능 + 최고 성능 | **nftables** | Full sync 최고속, 스케일아웃 최단, EKS 1.31+ |

## 알려진 이슈 및 해결

| 이슈 | 원인 | 해결 |
|-----|------|------|
| kube-proxy 메트릭 수집 불가 | distroless 이미지에 curl 없음 | `curlimages/curl` debug pod 사용 |
| fortio Pod Pending | 노드당 58 Pod 제한 (ENI) | nginx replicas 200 → 180 |
| ipvs/nftables 노드 조인 실패 | VPC 엔드포인트 SG 미등록 | 공유 VPC 엔드포인트 SG에 클러스터 SG 추가 |
| conntrack-monitor CrashLoop | `/proc/sys` 마운트 containerd 제한 | `/host/proc/sys`로 변경 |
| Prometheus PVC Pending | storageClassName 미지정 | `storageClassName: gp2` 추가 |

## 참고 자료

- [Kubernetes kube-proxy Modes](https://kubernetes.io/docs/reference/networking/virtual-ips/)
- [EKS kube-proxy Add-on](https://docs.aws.amazon.com/eks/latest/userguide/managing-kube-proxy.html)
- [nftables in Kubernetes (KEP-3866)](https://github.com/kubernetes/enhancements/tree/master/keps/sig-network/3866-nftables-proxy)
- [IPVS-Based In-Cluster Load Balancing](https://kubernetes.io/blog/2018/07/09/ipvs-based-in-cluster-load-balancing-deep-dive/)
- [conntrack-tools](https://conntrack-tools.netfilter.org/)
- [fortio](https://fortio.org/)

---

# English

A project to compare and analyze **conntrack table sync time**, **packet processing performance**, and **node scale-out impact** across kube-proxy modes (iptables / ipvs / nftables) in EKS 1.35.

## Background

When nodes are added via autoscaling in EKS, kube-proxy initializes (Full Sync) all existing Service/EndpointSlice rules, which can cause **delays of tens to hundreds of seconds**. This project compares the three kube-proxy modes under identical conditions to provide evidence for selecting the optimal mode.

## Key Findings

### Initial Full Sync Duration (101 Services)

```
iptables  ████████████████████████████████████████  29.55s
ipvs      ██                                        ~1-2s (estimated)
nftables  ██                                        1.56s

→ iptables is 15-19x slower than ipvs/nftables
```

> **Production estimate**: 500 Services → ~150s, 1000 Services → ~300s (iptables scales linearly)

### Fortio Load Test Results

**1,000 concurrent connections / 300s**

| Metric | iptables | ipvs | nftables |
|--------|---------|------|---------|
| QPS | **39,036** | 31,702 | 37,558 |
| P50 | **25ms** | 32ms | 27ms |
| P99 | **121ms** | 170ms | 202ms |

**5,000 concurrent connections / 300s**

| Metric | iptables | ipvs | nftables |
|--------|---------|------|---------|
| QPS | **39,419** | 31,891 | 37,375 |
| P50 | 153ms | 190ms | **150ms** |
| P99 | 491ms | 400ms | **391ms** |

### Node Scale-Out Total Time

| Phase | iptables | ipvs | nftables |
|-------|---------|------|---------|
| Node Ready | 44s | 76s | 44s |
| kube-proxy initial sync | **29.5s** | **~1-2s** | **1.6s** |
| **Total time to service** | **~73.5s** | **~78s** | **~45.6s** |

### Mode Comparison Summary

| Characteristic | iptables | ipvs | nftables |
|---------------|---------|------|---------|
| Initial Full Sync | 29.55s | ~1-2s | 1.56s |
| Regular Sync avg | 0.737s | 0.232s | 0.260s |
| iptables NAT rules | 54,214 | N/A (hash) | N/A (nft set) |
| QPS (1K conn) | 39,036 | 31,702 | 37,558 |
| P99 (5K conn) | 491ms | 400ms | 391ms |
| Scale-out total | ~73.5s | ~78s | ~45.6s |
| Maturity | Most proven | Stable | Newest (EKS 1.31+) |

> See [`results/analysis-report.md`](results/analysis-report.md) for detailed analysis.

## Architecture

```
                        ┌─────────────────────────────────────────────┐
                        │          Shared VPC (private subnets)        │
                        │                                             │
┌───────────────┐  ┌────┴────────────┐  ┌──────────────────┐  ┌──────┴───────────┐
│ ekscluster01  │  │ ekscluster01    │  │ ekscluster01     │  │  VPC Endpoints   │
│ -iptables     │  │ -ipvs           │  │ -nftables        │  │  (ECR,STS,EC2..) │
│               │  │                 │  │                  │  └──────────────────┘
│ kube-proxy:   │  │ kube-proxy:     │  │ kube-proxy:      │
│   iptables    │  │   ipvs (rr)     │  │   nftables       │
│ m6g.xlarge×4  │  │ m6g.xlarge×4    │  │ m6g.xlarge×4     │
└───────┬───────┘  └───────┬─────────┘  └────────┬─────────┘
        └──────────────────┼──────────────────────┘
              ┌────────────┴────────────┐
              │   Common per cluster     │
              │  - Nginx 180 replicas   │
              │  - ClusterIP Svc × 101  │
              │  - fortio load gen      │
              │  - conntrack-monitor DS │
              │  - Prometheus + Grafana │
              └─────────────────────────┘
```

## Test Environment

| Item | Value |
|------|-------|
| EKS Version | 1.35.2 |
| kube-proxy | v1.35.2-eksbuild.4 |
| Nodes | m6g.xlarge × 4 (Graviton ARM64, 4vCPU/16GiB) |
| AMI | Amazon Linux 2023 (kernel 6.12) |
| Network | Private subnet only, NAT Gateway |
| Services | 101 (ClusterIP) |
| EndpointSlices | 201 |
| Backend Pods | 180 (Nginx) |
| Load tool | fortio v1.75.1 |
| Monitoring | kube-prometheus-stack (Helm) |
| Region | ap-northeast-2 |

## Prerequisites

- AWS CLI v2 with appropriate IAM permissions
- eksctl v0.200+
- kubectl v1.35+
- Helm v3.x
- bash 4.x+

## Quick Start

### 1. Create Clusters

```bash
# Create all 3 clusters (~45-75 min)
./01.create-clusters.sh all

# Or individually
./01.create-clusters.sh iptables
./01.create-clusters.sh ipvs
./01.create-clusters.sh nftables
```

### 2. Deploy Monitoring

```bash
./02.deploy-monitoring.sh
```

### 3. Deploy Test Workloads

```bash
./03.deploy-test-workload.sh
```

### 4. Run Load Tests + Collect Metrics

```bash
# All clusters (4 load stages + node scale-out test)
./04.run-conntrack-test.sh

# Specific cluster
./04.run-conntrack-test.sh ekscluster01-iptables
```

### 5. Cleanup

```bash
./05.cleanup-clusters.sh
```

## Project Structure

```
eks-iptable/
├── 01.create-clusters.sh        # Create 3 EKS clusters (eksctl)
├── 02.deploy-monitoring.sh      # Deploy monitoring stack
├── 03.deploy-test-workload.sh   # Deploy Nginx + 100 Services + fortio
├── 04.run-conntrack-test.sh     # Run load tests + collect metrics + scale-out test
├── 05.cleanup-clusters.sh       # Cleanup all resources
│
├── templates/
│   └── eksctl-cluster.yaml.tpl  # eksctl cluster template (envsubst)
│
├── manifests/
│   ├── conntrack-monitor-ds.yaml        # conntrack stats collector DaemonSet
│   ├── prometheus-stack/values.yaml     # kube-prometheus-stack Helm values
│   ├── test-services.yaml               # Nginx Deployment (180 replicas)
│   └── fortio-loadgen.yaml              # fortio load generator
│
├── ekscluster01-iptables.yaml   # iptables cluster eksctl config
├── ekscluster01-ipvs.yaml       # ipvs cluster eksctl config
├── ekscluster01-nftables.yaml   # nftables cluster eksctl config
│
├── results/                     # Test results
│   ├── analysis-report.md       # Comprehensive analysis report
│   ├── *_conntrack.json         # conntrack metrics
│   ├── *_kubeproxy.txt          # kube-proxy sync duration metrics
│   ├── *_kubeproxy_full.txt     # Full node kube-proxy metrics
│   └── *_scaleout_sync.txt      # Node scale-out sync results
│
├── docs/
│   ├── architecture.md          # Architecture documentation
│   ├── decisions/               # ADRs (Architecture Decision Records)
│   └── runbooks/                # Operational runbooks
│
├── CLAUDE.md                    # Project context
└── README.md
```

## Collected Metrics

### kube-proxy (node :10249/metrics)

| Metric | Description | Applicable Modes |
|--------|------------|-----------------|
| `kubeproxy_sync_proxy_rules_duration_seconds` | Incremental sync duration | All |
| `kubeproxy_sync_full_proxy_rules_duration_seconds` | Full sync duration | iptables, nftables |
| `kubeproxy_sync_proxy_rules_iptables_total` | Total iptables rules | iptables |
| `kubeproxy_network_programming_duration_seconds` | Network programming latency | All |

### conntrack (DaemonSet collection)

| Metric | Description |
|--------|------------|
| `nf_conntrack_count` | Current conntrack entries |
| `nf_conntrack_max` | Max conntrack table size |
| `conntrack -S` insert/insert_failed/drop | conntrack statistics |

### fortio

| Metric | Description |
|--------|------------|
| QPS | Queries per second |
| P50 / P90 / P99 / P99.9 | Response latency percentiles |
| Code 200 ratio | Success rate |

## Recommendations

| Environment | Recommended Mode | Reason |
|------------|-----------------|--------|
| Frequent autoscaling | **nftables** or **ipvs** | iptables initial sync scales linearly with Service count |
| Large-scale Services (500+) | **ipvs** or **nftables** | iptables O(n) sequential rule traversal degrades packet processing |
| Stability priority | **ipvs** | Long-proven alternative, stable P99 tail latency |
| Latest features + best perf | **nftables** | Fastest full sync, shortest scale-out time, EKS 1.31+ |

## Known Issues & Workarounds

| Issue | Cause | Solution |
|-------|-------|----------|
| Cannot collect kube-proxy metrics | Distroless image has no curl | Use `curlimages/curl` debug pod |
| fortio Pod Pending | 58 pods/node limit (ENI) | Reduce nginx replicas to 180 |
| ipvs/nftables node join failure | VPC endpoint SG missing cluster SG | Add all cluster SGs to shared VPC endpoint SG |
| conntrack-monitor CrashLoop | `/proc/sys` mount blocked by containerd | Mount to `/host/proc/sys` instead |
| Prometheus PVC Pending | No storageClassName set | Add `storageClassName: gp2` |

## References

- [Kubernetes kube-proxy Modes](https://kubernetes.io/docs/reference/networking/virtual-ips/)
- [EKS kube-proxy Add-on](https://docs.aws.amazon.com/eks/latest/userguide/managing-kube-proxy.html)
- [nftables in Kubernetes (KEP-3866)](https://github.com/kubernetes/enhancements/tree/master/keps/sig-network/3866-nftables-proxy)
- [IPVS-Based In-Cluster Load Balancing](https://kubernetes.io/blog/2018/07/09/ipvs-based-in-cluster-load-balancing-deep-dive/)
- [conntrack-tools](https://conntrack-tools.netfilter.org/)
- [fortio](https://fortio.org/)

---

## Contributors

| GitHub | Name |
|--------|------|
| [@whchoi98](https://github.com/whchoi98) | Woo Hyung Choi |

## License

This project is for internal testing and analysis purposes.
