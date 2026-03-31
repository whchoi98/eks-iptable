---
sidebar_position: 3
title: "모니터링 구성"
description: "conntrack-monitor DaemonSet과 kube-prometheus-stack을 활용한 메트릭 수집 환경"
---

# 모니터링 구성

## conntrack-monitor DaemonSet

### 개요

각 노드의 conntrack table 상태를 실시간으로 수집하는 DaemonSet입니다.

### 수집 메트릭

| 메트릭 | 소스 | 설명 |
|--------|------|------|
| `nf_conntrack_count` | `/host/proc/sys/net/netfilter/nf_conntrack_count` | 현재 conntrack 엔트리 수 |
| `nf_conntrack_max` | `/host/proc/sys/net/netfilter/nf_conntrack_max` | 최대 conntrack 엔트리 수 |
| `insert` | `conntrack -S` | conntrack insert 횟수 |
| `insert_failed` | `conntrack -S` | insert 실패 횟수 |
| `drop` | `conntrack -S` | drop 횟수 |

### 핵심 설정

```yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: conntrack-monitor
spec:
  template:
    spec:
      hostNetwork: true
      hostPID: true
      containers:
        - name: monitor
          securityContext:
            privileged: true
          volumeMounts:
            - name: proc-sys
              mountPath: /host/proc/sys
              readOnly: true
      volumes:
        - name: proc-sys
          hostPath:
            path: /proc/sys
```

:::warning /proc/sys vs /host/proc/sys
containerd 보안 정책에 의해 컨테이너 내부의 `/proc/sys`는 호스트의 값과 다를 수 있습니다. 반드시 호스트의 `/proc/sys`를 `/host/proc/sys`로 마운트하여 읽어야 합니다.

```bash
# 잘못된 방법 (컨테이너 namespace 값)
cat /proc/sys/net/netfilter/nf_conntrack_count

# 올바른 방법 (호스트 값)
cat /host/proc/sys/net/netfilter/nf_conntrack_count
```
:::

### 수집 주기 및 출력 형식

5초 간격으로 JSON 형태의 로그를 출력합니다:

```json
{
  "timestamp": "2025-03-15T10:30:00Z",
  "node": "ip-10-0-1-123.ap-northeast-2.compute.internal",
  "nf_conntrack_count": 2208,
  "nf_conntrack_max": 131072,
  "conntrack_stats": {
    "insert": 45230,
    "insert_failed": 0,
    "drop": 0
  }
}
```

## kube-prometheus-stack

### Helm 배포

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

helm install monitoring prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --create-namespace \
  --set prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.resources.requests.storage=20Gi \
  --set prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.storageClassName=gp2 \
  --set grafana.adminPassword=conntrack-lab
```

### 구성 요소

| 컴포넌트 | 설정 | 비고 |
|----------|------|------|
| Prometheus | 20Gi gp2 PVC | 메트릭 저장소 |
| Grafana | admin / `conntrack-lab` | 대시보드 |
| node-exporter | 기본 설정 | 노드 메트릭 |
| kube-state-metrics | 기본 설정 | K8s 오브젝트 메트릭 |

### kube-proxy 메트릭 수집

kube-proxy의 메트릭을 수집하기 위해 추가 scrape config를 설정합니다:

```yaml
prometheus:
  prometheusSpec:
    additionalScrapeConfigs:
      - job_name: 'kube-proxy'
        kubernetes_sd_configs:
          - role: node
        relabel_configs:
          - source_labels: [__address__]
            regex: (.+):(.+)
            target_label: __address__
            replacement: ${1}:10249
        metrics_path: /metrics
        scheme: http
```

### 주요 수집 메트릭

```promql
# kube-proxy rule sync 시간
kubeproxy_sync_proxy_rules_duration_seconds

# Full sync 시간 (iptables, nftables만 해당)
kubeproxy_sync_full_proxy_rules_duration_seconds

# conntrack table 사용률
node_nf_conntrack_entries / node_nf_conntrack_entries_limit
```

:::tip kube-proxy distroless 이미지 메트릭 수집
kube-proxy는 distroless 이미지를 사용하므로, `kubectl exec`로 컨테이너에 접근하여 curl을 실행할 수 없습니다. 메트릭을 수동으로 확인하려면 별도의 curl debug Pod를 사용해야 합니다.

```bash
# debug Pod로 kube-proxy 메트릭 확인
kubectl run curl-debug --image=curlimages/curl --rm -it --restart=Never -- \
  curl -s http://<node-ip>:10249/metrics | grep kubeproxy_sync
```
:::
