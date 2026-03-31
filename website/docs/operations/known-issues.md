---
sidebar_position: 2
title: "알려진 이슈"
description: "EKS kube-proxy 테스트 환경에서 발견된 이슈와 해결 방법"
---

# 알려진 이슈

## 이슈 요약

| 이슈 | 증상 | 원인 | 해결 방법 |
|------|------|------|----------|
| kube-proxy 메트릭 수집 불가 | `kubectl exec` 실패 | distroless 이미지 | curl debug Pod 사용 |
| fortio Pod Pending | Pod가 스케줄링 안됨 | 58 pods/node ENI 제한 | nginx 180 replicas로 축소 |
| 노드 Join 실패 | Node NotReady | VPC Endpoint SG 누락 | 모든 클러스터 SG 추가 |
| conntrack-monitor CrashLoop | 컨테이너 재시작 반복 | `/proc/sys` 마운트 오류 | `/host/proc/sys` 사용 |
| Prometheus PVC Pending | PVC Bound 안됨 | storageClassName 미지정 | `gp2` 명시 |

---

## 상세 설명

### 1. kube-proxy 메트릭 수집 불가

**증상:**

```bash
$ kubectl exec -n kube-system kube-proxy-xxxxx -- curl localhost:10249/metrics
# OCI runtime exec failed: exec failed: unable to start container process:
# exec: "curl": executable file not found in $PATH
```

**원인:**

kube-proxy 컨테이너 이미지는 **distroless** 기반으로, shell이나 curl 같은 도구가 포함되어 있지 않습니다.

**해결:**

```bash
# curl debug Pod를 사용하여 메트릭 수집
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')

kubectl run curl-debug \
  --image=curlimages/curl \
  --rm -it --restart=Never -- \
  curl -s http://${NODE_IP}:10249/metrics | grep kubeproxy_sync
```

:::tip
kube-proxy 메트릭은 **hostNetwork** 모드로 동작하므로, 노드 IP의 포트 10249로 접근할 수 있습니다.
:::

---

### 2. fortio Pod Pending

**증상:**

```bash
$ kubectl get pods -n conntrack-test
NAME                     READY   STATUS    RESTARTS   AGE
nginx-xxxxxx-xxxxx       1/1     Running   0          5m
nginx-xxxxxx-yyyyy       0/1     Pending   0          5m  # Pending!
```

```
Events:
  Warning  FailedScheduling  0/4 nodes are available: 4 Too many pods
```

**원인:**

m6g.xlarge 인스턴스의 ENI 기반 Pod IP 할당 제한으로 **노드당 최대 58개 Pod**만 배치할 수 있습니다.

```
m6g.xlarge ENI 제한:
  ENI 수: 4개
  ENI당 IPv4: 15개
  최대 Pod: (4 × 15) - 1 = 59 → 실효 58개

4 노드 × 58 = 232개 (이론상 최대)
시스템 Pod (~20개) 제외 → 실효 ~212개
```

**해결:**

Nginx backend replicas를 **200 → 180**으로 축소합니다.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx-backend
spec:
  replicas: 180  # 200이 아닌 180
```

---

### 3. 노드 Join 실패

**증상:**

```bash
$ kubectl get nodes
# 새로 추가한 노드가 NotReady 또는 나타나지 않음
```

kubelet 로그:

```
Unable to connect to the server: dial tcp 10.0.x.x:443: i/o timeout
```

**원인:**

Private Subnet 전용 클러스터에서 VPC Endpoint의 Security Group이 새 클러스터의 SG를 포함하지 않으면, 노드가 API Server에 접근할 수 없습니다.

**해결:**

```bash
# 1. 클러스터 SG 확인
CLUSTER_SG=$(aws eks describe-cluster --name ekscluster01-ipvs \
  --query 'cluster.resourcesVpcConfig.clusterSecurityGroupId' --output text)

# 2. VPC Endpoint 목록 확인
aws ec2 describe-vpc-endpoints \
  --filters "Name=vpc-id,Values=vpc-0151a6dcd10c1c738" \
  --query 'VpcEndpoints[].{Id:VpcEndpointId,Service:ServiceName}'

# 3. 각 VPC Endpoint SG에 클러스터 SG 추가
aws ec2 modify-vpc-endpoint \
  --vpc-endpoint-id vpce-xxx \
  --add-security-group-ids ${CLUSTER_SG}
```

:::warning
3개 클러스터를 순차 생성할 때, **매 클러스터 생성 후** 해당 SG를 VPC Endpoint에 추가해야 합니다. 이 단계를 누락하면 ECR Pull 실패, CoreDNS 미시작 등 다양한 문제가 연쇄 발생합니다.
:::

---

### 4. conntrack-monitor CrashLoop

**증상:**

```bash
$ kubectl get pods -n kube-system -l app=conntrack-monitor
NAME                      READY   STATUS             RESTARTS   AGE
conntrack-monitor-xxxxx   0/1     CrashLoopBackOff   5          10m
```

Pod 로그:

```
cat: /proc/sys/net/netfilter/nf_conntrack_count: No such file or directory
```

**원인:**

containerd의 보안 정책으로 컨테이너 내부의 `/proc/sys`는 호스트의 실제 값을 반영하지 않을 수 있습니다. conntrack 관련 파일이 컨테이너의 `/proc/sys` namespace에 존재하지 않습니다.

**해결:**

호스트의 `/proc/sys`를 `/host/proc/sys`로 마운트하여 접근합니다:

```yaml
volumes:
  - name: proc-sys
    hostPath:
      path: /proc/sys
containers:
  - name: monitor
    volumeMounts:
      - name: proc-sys
        mountPath: /host/proc/sys  # /proc/sys가 아닌 /host/proc/sys
        readOnly: true
```

스크립트에서도 경로를 변경합니다:

```bash
# 잘못된 경로
cat /proc/sys/net/netfilter/nf_conntrack_count

# 올바른 경로
cat /host/proc/sys/net/netfilter/nf_conntrack_count
```

---

### 5. Prometheus PVC Pending

**증상:**

```bash
$ kubectl get pvc -n monitoring
NAME                          STATUS    VOLUME   CAPACITY   ACCESS MODES
prometheus-monitoring-db-0    Pending                                    
```

Events:

```
no persistent volumes available for this claim and no storage class is set
```

**원인:**

kube-prometheus-stack Helm chart에서 `storageClassName`을 명시하지 않으면, 기본 StorageClass가 설정되어 있지 않은 클러스터에서 PVC가 Bound되지 않습니다.

**해결:**

Helm values에서 `gp2` StorageClass를 명시합니다:

```bash
helm install monitoring prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --create-namespace \
  --set prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.storageClassName=gp2 \
  --set prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.resources.requests.storage=20Gi
```

:::tip
EKS에서 `aws-ebs-csi-driver` addon이 설치되어 있어야 `gp2`/`gp3` StorageClass를 사용할 수 있습니다. 이 프로젝트에서는 addon 목록에 포함되어 있으므로 별도 설치가 필요 없습니다.
:::
