# EKS kube-proxy conntrack 분석

EKS 1.35에서 kube-proxy 모드별(iptables/ipvs/nftables) conntrack table sync 시간 영향도를 비교 분석하는 프로젝트.

## Tech Stack

- **IaC**: eksctl (bash 스크립트 + YAML 템플릿)
- **EKS**: 1.35, AL2023, m6g.xlarge (Graviton ARM64)
- **모니터링**: Prometheus + Grafana (kube-prometheus-stack Helm)
- **부하 테스트**: fortio
- **conntrack 수집**: privileged DaemonSet (conntrack-tools)

## 실행 순서

1. `./01.create-clusters.sh` — 3개 EKS 클러스터 생성 (~45-75분)
2. `./02.deploy-monitoring.sh` — 모니터링 스택 배포
3. `./03.deploy-test-workload.sh` — 테스트 Service 100개 + fortio 배포
4. `./04.run-conntrack-test.sh` — 부하 테스트 + 메트릭 수집
5. `./05.cleanup-clusters.sh` — 클러스터 삭제

## 클러스터 구성

| 클러스터 | kube-proxy 모드 | 노드 |
|---------|----------------|------|
| ekscluster01-iptables | iptables (기본) | m6g.xlarge × 4 |
| ekscluster01-ipvs | ipvs | m6g.xlarge × 4 |
| ekscluster01-nftables | nftables | m6g.xlarge × 4 |

동일 VPC (vpc-0151a6dcd10c1c738), private subnet only.

## 핵심 메트릭

- `kubeproxy_sync_proxy_rules_duration_seconds` — rule sync 시간
- `nf_conntrack_count` / `nf_conntrack_max` — conntrack table 상태
- `conntrack -S` 통계 — insert, insert_failed, drop
- fortio P99 latency — 서비스 응답 영향도
