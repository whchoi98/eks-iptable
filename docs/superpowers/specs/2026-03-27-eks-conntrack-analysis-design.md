# EKS kube-proxy 모드별 conntrack 영향도 분석 인프라 설계

## 목적

EKS 클러스터에서 kube-proxy의 3가지 모드(iptables, IPVS, nftables)에 따른 conntrack table sync 시간 차이와 서비스 성능 영향도를 비교 분석한다.

conntrack sync 시간이 오래 걸려 발생하는 성능 저하를 모드별로 정량 측정하여, 프로덕션 환경에 최적의 kube-proxy 모드를 선정하기 위한 근거 데이터를 확보한다.

## 결정 사항

| 항목 | 결정 |
|------|------|
| 클러스터 전략 | 3개 독립 클러스터 (모드별 완전 격리) |
| IaC 방식 | 단일 파라미터화 eksctl 스크립트 (기존 aws_lab_infra 패턴) |
| 테스트 방식 | 워크로드 부하 + 커널 레벨 conntrack 관찰 병행 |
| 네트워크 접근 | Private only (외부 미노출) |

## 아키텍처

### 클러스터 구성

```
VPC: vpc-0151a6dcd10c1c738 (10.11.0.0/16, DMZ VPC)
│
├── eksworkshop (기존, EKS 1.33) — 변경 없음
│
├── ekscluster01-iptables  (EKS 1.35, kube-proxy: iptables)
│   └── ng-iptables: m6g.xlarge × 4  (private subnet)
│
├── ekscluster01-ipvs      (EKS 1.35, kube-proxy: ipvs)
│   └── ng-ipvs: m6g.xlarge × 4     (private subnet)
│
└── ekscluster01-nftables  (EKS 1.35, kube-proxy: nftables)
    └── ng-nftables: m6g.xlarge × 4  (private subnet)
```

### 공통 클러스터 사양

| 항목 | 값 |
|------|------|
| EKS 버전 | 1.35 |
| VPC | vpc-0151a6dcd10c1c738 |
| Private Subnet A | subnet-015d50a97799cda56 (10.11.32.0/19, ap-northeast-2a) |
| Private Subnet B | subnet-061c509c3cdc3b047 (10.11.64.0/19, ap-northeast-2b) |
| API Endpoint | private only (endpointPublicAccess: false, endpointPrivateAccess: true) |
| 노드 인스턴스 타입 | m6g.xlarge (Graviton, 4 vCPU, 16 GiB) |
| 노드 수 | 4대 (desired=4, min=4, max=4) |
| AMI | AmazonLinux2023 (ARM64) |
| 볼륨 | 50 GiB gp3, encrypted |
| SSH 접근 | SSM only |
| IP 용량 확인 | Private Subnet A: 8,055 IPs, Private Subnet B: 8,054 IPs (충분) |

### kube-proxy 모드별 설정

**ekscluster01-iptables (기본)**
```yaml
addons:
  - name: kube-proxy
    version: v1.35.2-eksbuild.4
    # mode: iptables (기본값, 별도 설정 불필요)
```

**ekscluster01-ipvs**
```yaml
addons:
  - name: kube-proxy
    version: v1.35.2-eksbuild.4
    configurationValues: |
      mode: ipvs
      ipvs:
        scheduler: rr
        strictARP: true
```

**ekscluster01-nftables**
```yaml
addons:
  - name: kube-proxy
    version: v1.35.2-eksbuild.4
    configurationValues: |
      mode: nftables
```

### Add-on 구성 (EKS 1.35)

| Add-on | 버전 | 용도 |
|--------|------|------|
| vpc-cni | v1.21.1-eksbuild.5 | Pod 네트워킹 |
| coredns | v1.13.2-eksbuild.3 | DNS |
| kube-proxy | v1.35.2-eksbuild.4 | 모드별 설정 적용 |
| aws-ebs-csi-driver | v1.57.1-eksbuild.1 | PV 스토리지 |
| eks-pod-identity-agent | v1.3.10-eksbuild.2 | IAM Pod Identity |
| metrics-server | v0.8.1-eksbuild.4 | 리소스 메트릭 |
| amazon-cloudwatch-observability | v5.2.3-eksbuild.1 | Container Insights |

## conntrack 테스트 & 모니터링

### 테스트 워크로드 (3개 클러스터 동일 배포)

**대상 Service**
- Nginx 기반 ClusterIP Service × 100개
- 각 Service는 2개 replica로 구성
- conntrack entry를 대량 생성하기 위한 워크로드

**부하 생성기**
- fortio Pod에서 각 Service로 동시 connection 생성
- 테스트 시나리오 (단계별):
  1. 1,000 concurrent connections (워밍업)
  2. 5,000 concurrent connections
  3. 10,000 concurrent connections
  4. 50,000 concurrent connections (stress)
- 각 단계별 5분 유지 후 메트릭 수집

### conntrack 커널 메트릭 수집 (DaemonSet)

각 노드에서 privileged DaemonSet으로 수집:

| 메트릭 | 소스 | 의미 |
|--------|------|------|
| `nf_conntrack_count` | /proc/sys/net/netfilter/ | 현재 conntrack entry 수 |
| `nf_conntrack_max` | /proc/sys/net/netfilter/ | 최대 허용치 |
| `conntrack searched` | conntrack -S | 테이블 검색 횟수 |
| `conntrack found` | conntrack -S | 검색 성공 횟수 |
| `conntrack insert` | conntrack -S | entry 삽입 수 |
| `conntrack insert_failed` | conntrack -S | 삽입 실패 (테이블 풀) |
| `conntrack drop` | conntrack -S | 드롭된 패킷 |
| `conntrack early_drop` | conntrack -S | 조기 드롭 |

수집 주기: 부하 테스트 중 1초, 평상시 5초

### kube-proxy 메트릭 (Prometheus)

| 메트릭 | 의미 |
|--------|------|
| `kubeproxy_sync_proxy_rules_duration_seconds` | rule sync 시간 (핵심 지표) |
| `kubeproxy_sync_proxy_rules_endpoint_changes_total` | endpoint 변경 횟수 |
| `kubeproxy_network_programming_duration_seconds` | 네트워크 프로그래밍 소요 시간 |
| `kubeproxy_sync_proxy_rules_iptables_total` | iptables rule 수 (iptables 모드) |

### 시각화

- Prometheus + Grafana를 각 클러스터에 배포 (Helm chart)
- 3개 클러스터 결과를 비교하는 통합 대시보드

## 핵심 비교 지표 매트릭스

| 지표 | 의미 | 예상 차이점 |
|------|------|------------|
| sync_proxy_rules_duration | kube-proxy rule 동기화 시간 | iptables > ipvs ≈ nftables |
| nf_conntrack_count 증가율 | conntrack table 채움 속도 | 모드별 entry 관리 방식에 따라 상이 |
| conntrack insert_failed | 테이블 풀 실패율 | ipvs: 별도 conn table로 낮을 수 있음 |
| P99 응답 지연 | 실제 서비스 영향도 | sync 시간에 비례 |
| conntrack entry 처리량 | 초당 생성/삭제 성능 | nftables 최적화 가능성 |

## 디렉토리 구조

```
eks-iptable/
├── 01.create-clusters.sh          # 3개 클러스터 생성 (PROXY_MODE 파라미터)
├── 02.deploy-monitoring.sh        # Prometheus + conntrack DaemonSet 배포
├── 03.deploy-test-workload.sh     # 테스트 Service 100개 + fortio 배포
├── 04.run-conntrack-test.sh       # 부하 테스트 실행 + 결과 수집
├── 05.cleanup-clusters.sh         # 3개 클러스터 삭제
├── manifests/
│   ├── conntrack-monitor-ds.yaml  # conntrack 메트릭 수집 DaemonSet
│   ├── test-services.yaml         # Nginx ClusterIP Services × 100
│   ├── fortio-loadgen.yaml        # fortio 부하 생성기 Job
│   └── prometheus-stack/          # Prometheus + Grafana Helm values
│       └── values.yaml
├── templates/
│   └── eksctl-cluster.yaml.tpl    # eksctl ClusterConfig 템플릿
├── results/                       # 테스트 결과 CSV/JSON 저장
├── docs/
│   └── superpowers/
│       └── specs/
│           └── 2026-03-27-eks-conntrack-analysis-design.md
└── CLAUDE.md
```

## 실행 순서

1. `01.create-clusters.sh` — 3개 EKS 클러스터 순차 생성 (~45-75분)
2. `02.deploy-monitoring.sh` — 각 클러스터에 Prometheus + conntrack DaemonSet 배포
3. `03.deploy-test-workload.sh` — 테스트 Service 100개 + fortio 배포
4. `04.run-conntrack-test.sh` — 단계별 부하 테스트 실행, 결과 수집
5. 결과 분석 — `results/` 디렉토리에서 3개 클러스터 비교
6. `05.cleanup-clusters.sh` — 테스트 완료 후 클러스터 삭제

## 비용 예측

| 항목 | 단가 | 수량 | 시간당 비용 |
|------|------|------|-----------|
| EKS Control Plane | $0.10/hr | 3 | $0.30 |
| m6g.xlarge | $0.154/hr (서울) | 12 | $1.848 |
| **합계** | | | **$2.148/hr** |

테스트 4시간 기준: ~$8.60 (기존 eksworkshop 제외)
