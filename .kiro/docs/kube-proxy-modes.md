# kube-proxy 모드별 설정

## iptables (기본)

```yaml
addons:
  - name: kube-proxy
    version: v1.35.2-eksbuild.4
    # mode: iptables (기본값)
```

- `iptables-restore`로 전체 NAT 테이블 한번에 교체
- Full Sync 발생: `sync_full` 메트릭 존재
- NAT 룰 수가 Service 수에 비례 (101 Service → 54,214룰)
- 룰 체인 O(n) 순차 탐색

## ipvs

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

- `ipvsadm`으로 개별 virtual server 추가/삭제
- Full Sync 없음 (전체 덮어쓰기 방식 아님)
- 해시 기반 O(1) 조회
- sync 빈도 높지만 개별 sync 빠름

## nftables

```yaml
addons:
  - name: kube-proxy
    version: v1.35.2-eksbuild.4
    configurationValues: |
      mode: nftables
```

- nft 트랜잭션으로 전체 룰셋 원자적 교체
- Full Sync 발생: `sync_full` 메트릭 존재
- nft set 기반 O(1) 조회
- EKS 1.31+ 지원

## 핵심 비교

| 특성 | iptables | ipvs | nftables |
|------|---------|------|---------|
| Full Sync | 29.55s | ~1-2s | 1.56s |
| Regular Sync | 0.737s | 0.232s | 0.260s |
| 룰 조회 | O(n) 순차 | O(1) 해시 | O(1) set |
| 스케일아웃 총 시간 | ~73.5s | ~78s | ~45.6s |
