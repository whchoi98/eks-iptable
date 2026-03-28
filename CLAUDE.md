# EKS kube-proxy conntrack 분석

EKS 1.35에서 kube-proxy 모드별(iptables/ipvs/nftables) conntrack table sync 시간 영향도를 비교 분석하는 프로젝트.

## Tech Stack

- **IaC**: eksctl (bash 스크립트 + YAML 템플릿)
- **EKS**: 1.35, AL2023, m6g.xlarge (Graviton ARM64)
- **모니터링**: Prometheus + Grafana (kube-prometheus-stack Helm)
- **부하 테스트**: fortio v1.75.1
- **conntrack 수집**: privileged DaemonSet (conntrack-tools)
- **리전**: ap-northeast-2

## Project Structure

```
├── 01~05.*.sh          # 실행 스크립트 (순서대로 실행)
├── templates/           # eksctl YAML 템플릿
├── manifests/           # K8s 매니페스트 (DaemonSet, Helm values, 테스트 워크로드)
├── results/             # 테스트 결과 데이터 + 분석 보고서
├── ekscluster01-*.yaml  # 생성된 클러스터별 eksctl 설정
├── docs/                # 아키텍처 문서, ADR, Runbook
└── tools/               # 유틸리티 스크립트, 프롬프트
```

## 실행 순서

1. `./01.create-clusters.sh [iptables|ipvs|nftables|all]` — EKS 클러스터 생성 (~15-25분/개)
2. `./02.deploy-monitoring.sh` — conntrack-monitor DaemonSet + kube-prometheus-stack 배포
3. `./03.deploy-test-workload.sh` — Nginx 180 replicas + Service 100개 + fortio 배포
4. `./04.run-conntrack-test.sh [클러스터명]` — 부하 테스트 + 메트릭 수집 + 노드 스케일아웃 테스트
5. `./05.cleanup-clusters.sh` — 클러스터 삭제

## 클러스터 구성

| 클러스터 | kube-proxy 모드 | 노드 | 노드그룹 |
|---------|----------------|------|---------|
| ekscluster01-iptables | iptables (기본) | m6g.xlarge × 4 | ng-iptables |
| ekscluster01-ipvs | ipvs (scheduler: rr) | m6g.xlarge × 4 | ng-ipvs |
| ekscluster01-nftables | nftables | m6g.xlarge × 4 | ng-nftables |

동일 VPC (vpc-0151a6dcd10c1c738), private subnet only.

## Key Commands

```bash
# 클러스터 상태 확인
aws eks list-clusters --output table
kubectl --context ekscluster01-iptables get nodes

# kube-proxy 메트릭 수집 (curl debug pod 사용, distroless 이미지이므로 exec 불가)
kubectl run curl-test --image=curlimages/curl --restart=Never --rm -i -- \
  curl -s http://<NODE_IP>:10249/metrics

# fortio 부하 테스트
kubectl exec -n conntrack-test deployment/fortio-client -- \
  fortio load -c 1000 -t 300s -qps 0 http://svc-001.conntrack-test.svc.cluster.local:80

# conntrack 모니터 로그 확인
kubectl logs -n conntrack-monitor -l app=conntrack-monitor --tail=5
```

## 핵심 메트릭

- `kubeproxy_sync_proxy_rules_duration_seconds` — rule sync 시간
- `kubeproxy_sync_full_proxy_rules_duration_seconds` — full resync 시간 (iptables/nftables만)
- `kubeproxy_sync_proxy_rules_iptables_total` — iptables 룰 총 개수
- `nf_conntrack_count` / `nf_conntrack_max` — conntrack table 상태
- `conntrack -S` 통계 — insert, insert_failed, drop
- fortio P99 latency — 서비스 응답 영향도

## Conventions

- 스크립트는 `set -e`로 에러 시 중단
- 모든 스크립트는 `~/.bash_profile` 소싱 후 실행
- 클러스터 컨텍스트명은 클러스터명과 동일하게 설정 (`--alias`)
- manifests 내 DaemonSet은 hostNetwork + privileged로 노드 메트릭 접근
- conntrack-monitor는 `/host/proc/sys`로 마운트 (containerd 보안 제한)
- Prometheus storageClass: gp2
- 결과 파일은 `results/` 디렉토리에 `{클러스터}_{stage}_{타입}.{ext}` 형식

## Known Issues

- kube-proxy Pod는 distroless 이미지 → `kubectl exec curl` 불가, debug pod 사용 필요
- 노드당 최대 58 Pod (m6g.xlarge ENI 제한) → nginx replicas 180으로 제한
- VPC 엔드포인트 SG에 모든 클러스터 SG 추가 필요 (공유 VPC)
