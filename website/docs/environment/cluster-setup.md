---
sidebar_position: 2
title: "클러스터 구성"
description: "eksctl 템플릿 기반 3개 EKS 클러스터 생성 및 kube-proxy 모드별 설정"
---

# 클러스터 구성

## eksctl 템플릿 접근 방식

3개 클러스터를 동일한 YAML 템플릿에서 `envsubst`로 변수를 치환하여 생성합니다.

### 템플릿 변수

| 변수 | 설명 | 예시 |
|------|------|------|
| `CLUSTER_NAME` | 클러스터 이름 | `ekscluster01-iptables` |
| `PROXY_MODE` | kube-proxy 모드 | `iptables`, `ipvs`, `nftables` |
| `NODEGROUP_NAME` | 노드그룹 이름 | `ng-iptables` |
| `PROXY_CONFIG_VALUES` | kube-proxy addon 설정 JSON | `'{}'` 또는 설정값 |

### 템플릿 사용 예시

```bash
export CLUSTER_NAME="ekscluster01-iptables"
export PROXY_MODE="iptables"
export NODEGROUP_NAME="ng-iptables"
export PROXY_CONFIG_VALUES='{}'

envsubst < cluster-template.yaml | eksctl create cluster -f -
```

## kube-proxy 모드별 설정

### iptables (기본 모드)

별도의 `configurationValues` 설정이 필요 없습니다. EKS 기본값을 그대로 사용합니다.

```yaml
addons:
  - name: kube-proxy
    version: latest
    # configurationValues 생략 → 기본 iptables 모드
```

### ipvs 모드

```yaml
addons:
  - name: kube-proxy
    version: latest
    configurationValues: '{"mode": "ipvs", "ipvs": {"scheduler": "rr"}}'
```

### nftables 모드

```yaml
addons:
  - name: kube-proxy
    version: latest
    configurationValues: '{"mode": "nftables"}'
```

## 전체 Addon 목록

각 클러스터에 설치되는 EKS Addon입니다:

| Addon | 용도 | 비고 |
|-------|------|------|
| `vpc-cni` | Pod 네트워킹 | ENI 기반 IP 할당 |
| `coredns` | 클러스터 내부 DNS | |
| `kube-proxy` | Service 트래픽 라우팅 | 모드별 설정 상이 |
| `aws-ebs-csi-driver` | EBS 볼륨 프로비저닝 | Prometheus PVC용 |
| `eks-pod-identity-agent` | Pod Identity 인증 | |
| `metrics-server` | 리소스 메트릭 수집 | HPA 등에 사용 |
| `amazon-cloudwatch-observability` | CloudWatch 통합 | 로그/메트릭 전송 |

## 클러스터 생성 스크립트

```bash
# 전체 클러스터 생성 (약 45-75분 소요)
./01.create-clusters.sh all

# 개별 클러스터 생성
./01.create-clusters.sh iptables
./01.create-clusters.sh ipvs
./01.create-clusters.sh nftables
```

:::warning VPC Endpoint Security Group 이슈
공유 VPC에서 클러스터를 순차 생성할 때, 새로운 클러스터의 Security Group을 기존 VPC Endpoint SG에 수동으로 추가해야 합니다. 이를 누락하면 ECR 이미지 Pull 실패, STS 인증 실패 등이 발생합니다.

```bash
# 클러스터별 SG 확인
aws eks describe-cluster --name ekscluster01-iptables \
  --query 'cluster.resourcesVpcConfig.clusterSecurityGroupId'

# VPC Endpoint SG에 추가
aws ec2 modify-vpc-endpoint \
  --vpc-endpoint-id vpce-xxx \
  --add-security-group-ids sg-new-cluster
```
:::

:::warning Private Endpoint 설정
Private Subnet 전용 클러스터에서는 `endpointPrivateAccess: true`를 반드시 활성화해야 합니다. 이 설정이 없으면 Worker Node가 API Server에 Join할 수 없습니다.

```yaml
vpc:
  clusterEndpoints:
    privateAccess: true
    publicAccess: true  # 관리 머신에서 접근용
```
:::
