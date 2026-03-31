---
sidebar_position: 1
title: "빠른 시작"
description: "EKS kube-proxy 모드 비교 테스트 환경 구축부터 결과 수집까지 빠른 시작 가이드"
---

# 빠른 시작

## 사전 요구사항

| 도구 | 최소 버전 | 확인 명령 |
|------|----------|----------|
| AWS CLI | v2 | `aws --version` |
| eksctl | v0.200+ | `eksctl version` |
| kubectl | v1.35+ | `kubectl version --client` |
| Helm | v3.x | `helm version` |
| bash | 4.x+ | `bash --version` |

```bash
# 버전 확인 한번에 실행
aws --version && eksctl version && kubectl version --client && helm version --short && bash --version | head -1
```

## 5단계 실행

### Step 1: 클러스터 생성

3개의 EKS 클러스터(iptables, ipvs, nftables)를 생성합니다. 약 **45-75분** 소요됩니다.

```bash
./01.create-clusters.sh all
```

개별 클러스터를 생성할 수도 있습니다:

```bash
# 개별 생성
./01.create-clusters.sh iptables
./01.create-clusters.sh ipvs
./01.create-clusters.sh nftables
```

### Step 2: 모니터링 배포

kube-prometheus-stack과 conntrack-monitor DaemonSet을 각 클러스터에 배포합니다.

```bash
./02.deploy-monitoring.sh
```

### Step 3: 테스트 워크로드 배포

Nginx 백엔드(180 replicas), ClusterIP Service(101개), fortio 클라이언트를 배포합니다.

```bash
./03.deploy-test-workload.sh
```

### Step 4: 부하 테스트 및 메트릭 수집

fortio 부하 테스트를 실행하고 conntrack 메트릭을 수집합니다.

```bash
./04.run-conntrack-test.sh
```

### Step 5: 정리

모든 클러스터와 리소스를 삭제합니다.

```bash
./05.cleanup-clusters.sh
```

## 유용한 명령어

### 노드 상태 확인

```bash
# 클러스터별 컨텍스트 전환
aws eks update-kubeconfig --name ekscluster01-iptables --region ap-northeast-2
aws eks update-kubeconfig --name ekscluster01-ipvs --region ap-northeast-2
aws eks update-kubeconfig --name ekscluster01-nftables --region ap-northeast-2

# 노드 상태 확인
kubectl get nodes -o wide
```

### kube-proxy 메트릭 수집

:::tip kube-proxy는 distroless 이미지를 사용합니다
`kubectl exec`로 kube-proxy Pod에 접근하여 curl을 실행할 수 없습니다. 별도의 curl debug Pod를 사용하세요.
:::

```bash
# 노드 IP 확인
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')

# curl debug Pod로 메트릭 수집
kubectl run curl-debug --image=curlimages/curl --rm -it --restart=Never -- \
  curl -s http://${NODE_IP}:10249/metrics | grep kubeproxy_sync

# sync duration 확인
kubectl run curl-debug --image=curlimages/curl --rm -it --restart=Never -- \
  curl -s http://${NODE_IP}:10249/metrics | grep "kubeproxy_sync_proxy_rules_duration_seconds"

# full sync duration 확인 (iptables, nftables만)
kubectl run curl-debug --image=curlimages/curl --rm -it --restart=Never -- \
  curl -s http://${NODE_IP}:10249/metrics | grep "kubeproxy_sync_full_proxy_rules_duration"
```

### fortio 부하 테스트 실행

```bash
# 1,000 동시 연결, 300초
kubectl exec -n conntrack-test deploy/fortio-client -- \
  fortio load -c 1000 -t 300s -qps 0 \
  http://svc-001.conntrack-test.svc.cluster.local:80

# 5,000 동시 연결, 300초
kubectl exec -n conntrack-test deploy/fortio-client -- \
  fortio load -c 5000 -t 300s -qps 0 \
  http://svc-001.conntrack-test.svc.cluster.local:80
```

### conntrack 로그 확인

```bash
# conntrack-monitor DaemonSet 로그
kubectl logs -n kube-system -l app=conntrack-monitor --tail=10

# 특정 노드의 conntrack 통계
kubectl logs -n kube-system -l app=conntrack-monitor \
  --field-selector spec.nodeName=<node-name> --tail=5
```

### Grafana 접근

```bash
# Grafana 포트 포워딩
kubectl port-forward -n monitoring svc/monitoring-grafana 3000:80

# 브라우저에서 접근
# URL: http://localhost:3000
# 계정: admin / conntrack-lab
```
