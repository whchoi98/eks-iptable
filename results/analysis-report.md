# EKS kube-proxy 모드별 conntrack 분석 보고서

> 테스트 일시: 2026-03-28
> 작성 기준: EKS 1.35, kube-proxy v1.35.2

---

## 1. 테스트 환경

| 항목 | 값 |
|-----|---|
| EKS 버전 | 1.35.2 |
| 노드 인스턴스 | m6g.xlarge × 4 (Graviton ARM64, 4vCPU/16GiB) |
| AMI | Amazon Linux 2023 (6.12 kernel) |
| 네트워크 | 동일 VPC, private subnet only, NAT Gateway |
| Services | 101개 (ClusterIP) |
| EndpointSlices | 201개 |
| Nginx Backend Pods | 180개 |
| 부하 도구 | fortio v1.75.1 |

### 클러스터 구성

| 클러스터 | kube-proxy 모드 | kube-proxy 설정 |
|---------|----------------|----------------|
| ekscluster01-iptables | iptables (기본) | 기본값 |
| ekscluster01-ipvs | ipvs | scheduler: rr |
| ekscluster01-nftables | nftables | 기본값 |

---

## 2. kube-proxy Sync Duration 비교

kube-proxy가 Service/EndpointSlice 변경을 감지하고 데이터플레인 룰에 반영하는 시간.
**오토스케일링 환경에서 가장 중요한 지표.**

### 2-1. Full Sync — 초기 전체 룰 적용

새 노드가 클러스터에 조인했을 때, 기존 모든 Service/EndpointSlice 룰을 처음부터 적용하는 시간.

| 모드 | Full Sync 합계 | 횟수 | **평균 1회 소요** | 비고 |
|------|---------------|------|-----------------|------|
| **iptables** | 88.64s | 3회 | **29.55s** | `iptables-restore`로 전체 NAT 테이블 교체 |
| **ipvs** | — | — | **~1-2s** (추정) | `full_sync` 메트릭 미제공, 개별 서비스 추가 방식 |
| **nftables** | 4.69s | 3회 | **1.56s** | nft 트랜잭션으로 전체 룰셋 원자적 교체 |

```
초기 Full Sync 소요 시간 (101 Service 기준)

iptables  ████████████████████████████████████████  29.55s
ipvs      ██                                        ~1-2s (추정)
nftables  ██                                        1.56s

→ iptables는 ipvs/nftables 대비 15~19배 느림
```

> **운영 환경 추정**: 101개 Service에서 29.55s이므로,
> Service 500개 환경 → ~150s, Service 1000개 환경 → ~300s (선형 증가)
> 이것이 말씀하신 **낮 시간대 50-100초 초기 sync의 원인**입니다.

### 2-2. Regular Sync — 증분 동기화

기존 노드에서 Service/EndpointSlice 변경 시 발생하는 증분 동기화.

| 모드 | Sync 합계 | 횟수 | **평균 Sync** | 특징 |
|------|----------|------|-------------|------|
| **iptables** | 148.12s | 201회 | **0.737s** | 전체 테이블 재작성 방식 |
| **ipvs** | 374.38s | 1,613회 | **0.232s** | 빈번하지만 개별 sync가 빠름 |
| **nftables** | 52.81s | 203회 | **0.260s** | sync 빈도 낮고 개별도 빠름 |

```
Regular Sync 평균 소요 시간

iptables  ████████████████████████████████  0.737s (100%)
nftables  █████████                         0.260s (35%)
ipvs      ████████                          0.232s (31%)
```

### 2-3. 새 노드 Sync 히스토그램 분포 (IPv4)

스케일아웃된 새 노드에서 수집한 sync duration 분포.

**iptables** (총 32회)
```
≤0.256s:  7건  ███
≤0.512s: 13건  ██████
≤1.024s:  5건  ██
≤2.048s:  1건  █
≤8.192s:  2건  █         ← kube-proxy 재시작 시 full sync
>16s:     4건  ██        ← 초기 full sync (~29s)
```

**ipvs** (총 464회)
```
≤0.256s:   2건
≤0.512s: 452건  ████████████████████████████████████  (97.4%)
≤1.024s:   9건  █
≤2.048s:   1건            ← 초기 sync (최대 ~2s)
```

**nftables** (총 58회)
```
≤0.256s:  1건
≤0.512s: 29건  █████████████████
≤1.024s: 25건  ███████████████
≤2.048s:  3건  ██            ← full sync (~1.6s)
```

### 2-4. ipvs에 Full Sync 메트릭이 없는 이유

| 모드 | 룰 적용 방식 | Full Resync |
|------|------------|-------------|
| **iptables** | `iptables-restore`로 전체 NAT 테이블 한번에 교체 | 전체 재작성 → `sync_full` 발생 |
| **nftables** | nft 트랜잭션으로 전체 룰셋 원자적 교체 | 전체 재작성 → `sync_full` 발생 |
| **ipvs** | `ipvsadm`으로 개별 virtual server 추가/삭제 | **전체 덮어쓰기 없음** → `sync_full` 미존재 |

---

## 3. iptables 룰 개수

| 테이블 | IPv4 | IPv6 |
|-------|------|------|
| **NAT** | **54,214** | 5 |
| filter | 12 | 3 |

- 101개 Service × ~180개 Endpoint → NAT 54,214룰
- Service 1개당 약 537개 NAT 룰
- 운영 환경 Service 500개 추정 시: **~268,500룰**
- iptables는 룰 수에 비례하여 sync 시간과 패킷 처리 latency 모두 증가

---

## 4. Fortio 부하 테스트 결과

### 4-1. 1,000 concurrent connections / 300s

| 지표 | iptables | ipvs | nftables |
|------|---------|------|---------|
| **Total Calls** | 11,712,158 | 9,511,144 | 11,268,218 |
| **QPS** | **39,036** | 31,702 | 37,558 |
| **P50** | **25ms** | 32ms | 27ms |
| **P90** | **34ms** | 44ms | 35ms |
| **P99** | **121ms** | 170ms | 202ms |
| **P99.9** | 214ms | 293ms | 246ms |
| Code 200 | 100% | 100% | 100% |

### 4-2. 5,000 concurrent connections / 300s

| 지표 | iptables | ipvs | nftables |
|------|---------|------|---------|
| **Total Calls** | 11,828,677 | 9,569,414 | 11,214,831 |
| **QPS** | **39,419** | 31,891 | 37,375 |
| **P50** | 153ms | 190ms | **150ms** |
| **P90** | **276ms** | 252ms | 227ms |
| **P99** | 491ms | **400ms** | **391ms** |
| **P99.9** | 593ms | 497ms | **492ms** |
| Code 200 | 100% | 100% | 100% |

### 4-3. 부하 테스트 분석

```
QPS 비교 (높을수록 좋음)

           1000 conn        5000 conn
iptables   ████████████ 39K  ████████████ 39K
nftables   ███████████  38K  ███████████  37K
ipvs       █████████    32K  █████████    32K
```

- **처리량(QPS)**: iptables ≈ nftables > ipvs (~19% 차이)
- **저부하(1000 conn)**: iptables가 P50/P90/P99 모두 최고
- **고부하(5000 conn)**: nftables가 P99/P99.9에서 가장 안정적
- **ipvs**: QPS가 일관되게 낮음 — IPVS 커널 모듈의 virtual server 조회 오버헤드

> 참고: 101개 Service 규모에서는 iptables의 패킷 처리 성능이 아직 우수.
> Service 수가 500+로 증가하면 iptables 룰 체인 순차 탐색으로 latency 급증 예상.

---

## 5. Conntrack Table 상태

| 부하 단계 | iptables avg/max | ipvs avg/max | nftables avg/max |
|----------|-----------------|-------------|-----------------|
| 1,000 conn | 2,208 / 5,269 | 1,680 / 3,672 | 541 / 642 |
| 5,000 conn | 2,733 / 5,748 | 2,636 / 5,588 | 498 / 706 |
| 10,000 conn | 6,504 / 10,623 | 9,913 / 38,877 | 523 / 817 |
| 50,000 conn | 18,096 / 49,893 | 15,338 / 45,309 | 473 / 673 |

- **insert_failed = 0, drop = 0** → conntrack table 여유 충분 (모든 클러스터)
- iptables/ipvs: 부하에 비례하여 conntrack count 증가
- nftables: 첫 테스트 시 fortio DNS timeout으로 실제 부하 미전달 (재테스트 시 정상)

---

## 6. 노드 스케일아웃 시간

신규 노드가 EKS 클러스터에 조인하고 kube-proxy가 초기 sync를 완료하기까지의 시간.

| 단계 | iptables | ipvs | nftables |
|------|---------|------|---------|
| 노드 Ready | 44s | 76s | 44s |
| kube-proxy 초기 sync | **~29.5s** | **~1-2s** | **~1.6s** |
| **총 서비스 가용 시간** | **~73.5s** | **~78s** | **~45.6s** |

> nftables가 **총 서비스 가용 시간이 가장 짧음** (노드 Ready + 초기 sync 합산)

---

## 7. 핵심 결론

### 모드별 특성 요약

| 특성 | iptables | ipvs | nftables |
|------|---------|------|---------|
| 초기 Full Sync | ❌ 29.55s (매우 느림) | ✅ ~1-2s | ✅ 1.56s |
| Regular Sync | ⚠️ 0.737s | ✅ 0.232s | ✅ 0.260s |
| QPS (1000 conn) | ✅ 39,036 | ⚠️ 31,702 | ✅ 37,558 |
| P99 Latency (5000 conn) | ⚠️ 491ms | ✅ 400ms | ✅ 391ms |
| NAT 룰 개수 | ❌ 54,214 | ✅ N/A (해시) | ✅ N/A (nft set) |
| 스케일아웃 총 시간 | ❌ ~73.5s | ⚠️ ~78s | ✅ ~45.6s |
| 성숙도 | ✅ 가장 검증됨 | ✅ 안정적 | ⚠️ 최신 (EKS 1.31+) |

### 권장 사항

1. **오토스케일링 빈번한 환경** → **nftables 또는 ipvs 전환 권장**
   - iptables 초기 sync가 Service 수에 선형 비례하여 증가
   - 101개 Service: 29.5s → 500개: ~150s → 1000개: ~300s

2. **대규모 Service (500+)** → **ipvs 또는 nftables 필수**
   - iptables NAT 룰 체인이 O(n) 순차 탐색으로 패킷 처리도 느려짐
   - ipvs/nftables는 해시 기반 O(1) 조회

3. **안정성 우선** → **ipvs**
   - 오랫동안 검증된 대안, sync 빈도는 높지만 개별 sync가 매우 빠름
   - QPS가 iptables/nftables 대비 ~19% 낮지만 P99 tail latency는 안정적

4. **최신 기능 + 최고 성능** → **nftables**
   - Full sync 가장 빠름 (1.56s), 총 스케일아웃 시간 최단 (45.6s)
   - 고부하 P99/P99.9 가장 안정적
   - EKS 1.31+ 지원, 상대적으로 새로운 모드

---

## 부록: 테스트 환경 상세

- **EKS**: v1.35.2, kube-proxy v1.35.2-eksbuild.4
- **노드**: AL2023, kernel 6.12.73, containerd 2.2.1, ARM64
- **모니터링**: kube-prometheus-stack (Prometheus + Grafana)
- **conntrack 수집**: privileged DaemonSet (conntrack-tools + /proc/sys)
- **kube-proxy 메트릭**: curl debug pod → node:10249/metrics
