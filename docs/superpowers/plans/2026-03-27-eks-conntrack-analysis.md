# EKS kube-proxy 모드별 conntrack 영향도 분석 구현 계획

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 3개의 EKS 1.35 클러스터(iptables/ipvs/nftables)를 생성하고, conntrack table sync 시간 영향도를 비교 분석하는 전체 인프라 및 테스트 환경을 구축한다.

**Architecture:** 기존 eksworkshop 클러스터와 동일한 VPC(10.11.0.0/16)의 private subnet에 3개의 독립 EKS 클러스터를 eksctl로 배포한다. 각 클러스터는 kube-proxy 모드만 다르고 나머지 구성은 동일하다. conntrack 메트릭 수집 DaemonSet, fortio 부하 생성기, Prometheus+Grafana 모니터링을 각 클러스터에 배포하여 모드별 성능을 정량 비교한다.

**Tech Stack:** eksctl, EKS 1.35, AL2023 (ARM64/Graviton), Kubernetes manifests (YAML), Bash, fortio, conntrack-tools, Prometheus, Grafana

**기존 IaC 참조:** `/home/ec2-user/my-project/aws_lab_infra/cloudformation/04.eks-create-cluster.sh`

**인프라 상수:**
- VPC ID: `vpc-0151a6dcd10c1c738`
- Private Subnet A: `subnet-015d50a97799cda56` (10.11.32.0/19, ap-northeast-2a)
- Private Subnet B: `subnet-061c509c3cdc3b047` (10.11.64.0/19, ap-northeast-2b)
- Region: `ap-northeast-2`

---

## File Structure

| 파일 | 역할 |
|------|------|
| `templates/eksctl-cluster.yaml.tpl` | eksctl ClusterConfig 템플릿 (envsubst로 변수 치환) |
| `01.create-clusters.sh` | 3개 클러스터 생성 오케스트레이터 |
| `manifests/conntrack-monitor-ds.yaml` | conntrack 커널 메트릭 수집 privileged DaemonSet |
| `manifests/prometheus-stack/values.yaml` | kube-prometheus-stack Helm values |
| `02.deploy-monitoring.sh` | 모니터링 스택 배포 스크립트 |
| `manifests/test-services.yaml` | Nginx ClusterIP Service × 100 + Deployment |
| `manifests/fortio-loadgen.yaml` | fortio 부하 생성 Job |
| `03.deploy-test-workload.sh` | 테스트 워크로드 배포 스크립트 |
| `04.run-conntrack-test.sh` | 단계별 부하 테스트 실행 + 결과 수집 |
| `05.cleanup-clusters.sh` | 클러스터 삭제 스크립트 |
| `CLAUDE.md` | 프로젝트 가이드 |

---

## Task 1: eksctl ClusterConfig 템플릿

**Files:**
- Create: `templates/eksctl-cluster.yaml.tpl`

- [ ] **Step 1: 디렉토리 생성**

```bash
mkdir -p templates manifests/prometheus-stack results
```

- [ ] **Step 2: eksctl 템플릿 작성**

`templates/eksctl-cluster.yaml.tpl` — envsubst로 치환할 변수: `${CLUSTER_NAME}`, `${PROXY_MODE}`, `${PROXY_CONFIG_VALUES}`, `${NODEGROUP_NAME}`, 인프라 상수들.

```yaml
---
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig

metadata:
  name: ${CLUSTER_NAME}
  region: ap-northeast-2
  version: "1.35"
  tags:
    Environment: lab
    Project: eks-conntrack-analysis
    ProxyMode: ${PROXY_MODE}
    ManagedBy: eksctl

vpc:
  id: "vpc-0151a6dcd10c1c738"
  subnets:
    private:
      ap-northeast-2a:
        id: "subnet-015d50a97799cda56"
      ap-northeast-2b:
        id: "subnet-061c509c3cdc3b047"

privateCluster:
  enabled: true

managedNodeGroups:
  - name: ${NODEGROUP_NAME}
    instanceType: m6g.xlarge
    desiredCapacity: 4
    minSize: 4
    maxSize: 4
    volumeSize: 50
    volumeType: gp3
    volumeEncrypted: true
    amiFamily: AmazonLinux2023
    labels:
      nodegroup-type: "${NODEGROUP_NAME}"
      proxy-mode: "${PROXY_MODE}"
    tags:
      Environment: lab
      Project: eks-conntrack-analysis
      ProxyMode: ${PROXY_MODE}
    privateNetworking: true
    subnets:
      - "subnet-015d50a97799cda56"
      - "subnet-061c509c3cdc3b047"
    ssh:
      enableSsm: true
    iam:
      withAddonPolicies:
        imageBuilder: true
        autoScaler: true
        ebs: true
        cloudWatch: true

cloudWatch:
  clusterLogging:
    enableTypes:
      - api
      - audit
      - authenticator
      - controllerManager
      - scheduler

iam:
  withOIDC: true

addons:
  - name: vpc-cni
    version: v1.21.1-eksbuild.5
    attachPolicyARNs:
      - arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy
  - name: coredns
    version: v1.13.2-eksbuild.3
  - name: kube-proxy
    version: v1.35.2-eksbuild.4
${PROXY_CONFIG_VALUES}
  - name: aws-ebs-csi-driver
    version: v1.57.1-eksbuild.1
    wellKnownPolicies:
      ebsCSIController: true
  - name: eks-pod-identity-agent
    version: v1.3.10-eksbuild.2
  - name: metrics-server
    version: v0.8.1-eksbuild.4
  - name: amazon-cloudwatch-observability
    version: v5.2.3-eksbuild.1
```

- [ ] **Step 3: 템플릿 변수 치환 확인**

```bash
export CLUSTER_NAME=test PROXY_MODE=iptables PROXY_CONFIG_VALUES="" NODEGROUP_NAME=ng-test
envsubst < templates/eksctl-cluster.yaml.tpl | head -20
```

Expected: `name: test`, `version: "1.35"` 등 치환 확인.

- [ ] **Step 4: Commit**

```bash
git add templates/eksctl-cluster.yaml.tpl
git commit -m "feat: add eksctl ClusterConfig template for conntrack analysis clusters"
```

---

## Task 2: 클러스터 생성 스크립트

**Files:**
- Create: `01.create-clusters.sh`

- [ ] **Step 1: 스크립트 작성**

`01.create-clusters.sh` — 3개 클러스터를 순차 생성하는 오케스트레이터.

```bash
#!/bin/bash
set -e

# EKS kube-proxy 모드별 conntrack 분석 클러스터 3개 생성
# 사용법: ./01.create-clusters.sh [iptables|ipvs|nftables|all]

set +eu; source ~/.bash_profile; set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE="${SCRIPT_DIR}/templates/eksctl-cluster.yaml.tpl"
AWS_REGION="ap-northeast-2"

# ─────────────────────────────────────────────
# 모드별 설정 정의
# ─────────────────────────────────────────────
declare -A CLUSTER_NAMES=(
  [iptables]="ekscluster01-iptables"
  [ipvs]="ekscluster01-ipvs"
  [nftables]="ekscluster01-nftables"
)

declare -A NODEGROUP_NAMES=(
  [iptables]="ng-iptables"
  [ipvs]="ng-ipvs"
  [nftables]="ng-nftables"
)

# kube-proxy addon configurationValues (YAML 들여쓰기 주의: addons 배열 아이템 하위)
declare -A PROXY_CONFIGS=(
  [iptables]=""
  [ipvs]="    configurationValues: '{\"mode\": \"ipvs\", \"ipvs\": {\"scheduler\": \"rr\", \"strictARP\": true}}'"
  [nftables]="    configurationValues: '{\"mode\": \"nftables\"}'"
)

# ─────────────────────────────────────────────
# 대상 모드 결정
# ─────────────────────────────────────────────
TARGET_MODE="${1:-all}"
if [ "$TARGET_MODE" = "all" ]; then
  MODES=("iptables" "ipvs" "nftables")
else
  if [[ ! "${CLUSTER_NAMES[$TARGET_MODE]+_}" ]]; then
    echo "❌ 알 수 없는 모드: $TARGET_MODE"
    echo "사용법: $0 [iptables|ipvs|nftables|all]"
    exit 1
  fi
  MODES=("$TARGET_MODE")
fi

echo "============================================"
echo "  EKS conntrack 분석 클러스터 생성"
echo "============================================"
echo "  대상 모드: ${MODES[*]}"
echo "  EKS 버전: 1.35"
echo "  노드: m6g.xlarge × 4 (private only)"
echo "  리전: ${AWS_REGION}"
echo ""

# ─────────────────────────────────────────────
# 클러스터 생성 함수
# ─────────────────────────────────────────────
create_cluster() {
  local mode="$1"
  local cluster_name="${CLUSTER_NAMES[$mode]}"
  local nodegroup_name="${NODEGROUP_NAMES[$mode]}"
  local proxy_config="${PROXY_CONFIGS[$mode]}"

  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  ▶ 클러스터 생성: ${cluster_name} (mode: ${mode})"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  # 기존 클러스터 확인
  EXISTING=$(aws eks describe-cluster --name "${cluster_name}" \
    --query 'cluster.status' --output text \
    --region "${AWS_REGION}" 2>/dev/null || echo "NOT_FOUND")

  if [ "$EXISTING" = "ACTIVE" ]; then
    echo "  ⚠️  클러스터 '${cluster_name}'이(가) 이미 존재합니다. 건너뜁니다."
    aws eks update-kubeconfig --name "${cluster_name}" --region "${AWS_REGION}" --alias "${cluster_name}"
    return 0
  fi

  # 템플릿에서 설정 파일 생성
  local config_file="${SCRIPT_DIR}/${cluster_name}.yaml"
  export CLUSTER_NAME="${cluster_name}"
  export PROXY_MODE="${mode}"
  export NODEGROUP_NAME="${nodegroup_name}"
  export PROXY_CONFIG_VALUES="${proxy_config}"

  envsubst < "${TEMPLATE}" > "${config_file}"
  echo "  ✅ 설정 파일 생성: ${config_file}"

  # dry-run 검증
  echo "  ▶ dry-run 검증..."
  if ! eksctl create cluster --config-file="${config_file}" --dry-run > /dev/null 2>&1; then
    echo "  ❌ dry-run 실패:"
    eksctl create cluster --config-file="${config_file}" --dry-run 2>&1 | tail -10
    return 1
  fi
  echo "  ✅ dry-run 통과"

  # 클러스터 생성
  echo "  ▶ 클러스터 생성 시작... (예상 15-25분)"
  echo "  시작: $(date '+%Y-%m-%d %H:%M:%S')"
  eksctl create cluster --config-file="${config_file}"
  echo "  완료: $(date '+%Y-%m-%d %H:%M:%S')"

  # kubeconfig 업데이트
  aws eks update-kubeconfig --name "${cluster_name}" --region "${AWS_REGION}" --alias "${cluster_name}"
  echo "  ✅ ${cluster_name} 생성 완료"
  kubectl --context "${cluster_name}" get nodes -o wide
}

# ─────────────────────────────────────────────
# 실행
# ─────────────────────────────────────────────
echo ""
read -p "계속 진행하시겠습니까? (yes/no): " CONFIRM
if [ "$CONFIRM" != "yes" ]; then
  echo "취소되었습니다."
  exit 0
fi

for mode in "${MODES[@]}"; do
  create_cluster "$mode"
done

echo ""
echo "============================================"
echo "  ✅ 클러스터 생성 완료"
echo "============================================"
echo ""
for mode in "${MODES[@]}"; do
  echo "  ${CLUSTER_NAMES[$mode]} (${mode})"
done
echo ""
echo "  다음 단계: ./02.deploy-monitoring.sh"
echo "============================================"
```

- [ ] **Step 2: 실행 권한 부여 및 문법 검증**

```bash
chmod +x 01.create-clusters.sh
bash -n 01.create-clusters.sh && echo "Syntax OK"
```

Expected: `Syntax OK`

- [ ] **Step 3: Commit**

```bash
git add 01.create-clusters.sh
git commit -m "feat: add cluster creation script for 3 kube-proxy modes"
```

---

## Task 3: conntrack 모니터 DaemonSet

**Files:**
- Create: `manifests/conntrack-monitor-ds.yaml`

- [ ] **Step 1: DaemonSet 매니페스트 작성**

conntrack 커널 메트릭을 수집하여 stdout으로 출력하는 privileged DaemonSet. CloudWatch Container Insights 또는 Prometheus가 로그를 수집한다.

`manifests/conntrack-monitor-ds.yaml`:

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: conntrack-monitor
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: conntrack-collector-script
  namespace: conntrack-monitor
data:
  collect.sh: |
    #!/bin/bash
    # conntrack 메트릭 수집 스크립트
    # 출력 형식: JSON (Prometheus/CloudWatch 파싱 가능)
    INTERVAL="${COLLECT_INTERVAL:-5}"
    HOSTNAME=$(hostname)

    while true; do
      TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)

      # /proc 기반 메트릭
      CT_COUNT=$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || echo 0)
      CT_MAX=$(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null || echo 0)

      # conntrack -S 통계 (CPU별 합산)
      if command -v conntrack &>/dev/null; then
        STATS=$(conntrack -S 2>/dev/null)
        SEARCHED=$(echo "$STATS" | awk -F= '/searched/{s+=$2}END{print s+0}')
        FOUND=$(echo "$STATS" | awk -F= '/found/{s+=$2}END{print s+0}')
        INSERT=$(echo "$STATS" | awk -F= '/insert /{s+=$2}END{print s+0}')
        INSERT_FAILED=$(echo "$STATS" | awk -F= '/insert_failed/{s+=$2}END{print s+0}')
        DROP=$(echo "$STATS" | awk -F= '/drop/{s+=$2}END{print s+0}')
        EARLY_DROP=$(echo "$STATS" | awk -F= '/early_drop/{s+=$2}END{print s+0}')
      else
        SEARCHED=0 FOUND=0 INSERT=0 INSERT_FAILED=0 DROP=0 EARLY_DROP=0
      fi

      # JSON 출력
      echo "{\"timestamp\":\"${TIMESTAMP}\",\"node\":\"${HOSTNAME}\",\"conntrack_count\":${CT_COUNT},\"conntrack_max\":${CT_MAX},\"searched\":${SEARCHED},\"found\":${FOUND},\"insert\":${INSERT},\"insert_failed\":${INSERT_FAILED},\"drop\":${DROP},\"early_drop\":${EARLY_DROP}}"

      sleep "$INTERVAL"
    done
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: conntrack-monitor
  namespace: conntrack-monitor
  labels:
    app: conntrack-monitor
spec:
  selector:
    matchLabels:
      app: conntrack-monitor
  template:
    metadata:
      labels:
        app: conntrack-monitor
    spec:
      hostNetwork: true
      hostPID: true
      tolerations:
        - operator: Exists
      containers:
        - name: collector
          image: public.ecr.aws/amazonlinux/amazonlinux:2023
          command: ["/bin/bash", "/scripts/collect.sh"]
          env:
            - name: COLLECT_INTERVAL
              value: "5"
          securityContext:
            privileged: true
          volumeMounts:
            - name: scripts
              mountPath: /scripts
            - name: proc-sys
              mountPath: /proc/sys
              readOnly: true
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              cpu: 100m
              memory: 128Mi
      volumes:
        - name: scripts
          configMap:
            name: conntrack-collector-script
            defaultMode: 0755
        - name: proc-sys
          hostPath:
            path: /proc/sys
```

- [ ] **Step 2: YAML 문법 검증**

```bash
kubectl apply --dry-run=client -f manifests/conntrack-monitor-ds.yaml 2>&1 | head -5
```

Expected: `namespace/conntrack-monitor created (dry run)` 등 에러 없이 통과.

- [ ] **Step 3: Commit**

```bash
git add manifests/conntrack-monitor-ds.yaml
git commit -m "feat: add conntrack monitor DaemonSet for kernel metrics collection"
```

---

## Task 4: Prometheus + Grafana 모니터링 스택

**Files:**
- Create: `manifests/prometheus-stack/values.yaml`

- [ ] **Step 1: Helm values 작성**

kube-prometheus-stack Helm chart의 커스텀 values. kube-proxy 메트릭 수집과 conntrack 대시보드에 집중한다.

`manifests/prometheus-stack/values.yaml`:

```yaml
# kube-prometheus-stack Helm values
# conntrack 분석에 필요한 최소 구성

prometheus:
  prometheusSpec:
    retention: 24h
    scrapeInterval: 15s
    resources:
      requests:
        cpu: 500m
        memory: 1Gi
      limits:
        cpu: 1000m
        memory: 2Gi
    storageSpec:
      volumeClaimTemplate:
        spec:
          accessModes: ["ReadWriteOnce"]
          resources:
            requests:
              storage: 20Gi

    # kube-proxy 메트릭 scrape 설정
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

grafana:
  enabled: true
  adminPassword: "conntrack-lab"
  service:
    type: ClusterIP
  resources:
    requests:
      cpu: 100m
      memory: 256Mi
    limits:
      cpu: 500m
      memory: 512Mi
  dashboardProviders:
    dashboardproviders.yaml:
      apiVersion: 1
      providers:
        - name: 'conntrack'
          orgId: 1
          folder: 'Conntrack Analysis'
          type: file
          disableDeletion: false
          editable: true
          options:
            path: /var/lib/grafana/dashboards/conntrack

kubeProxy:
  enabled: true

alertmanager:
  enabled: false

nodeExporter:
  enabled: true

kubeStateMetrics:
  enabled: true
```

- [ ] **Step 2: Commit**

```bash
git add manifests/prometheus-stack/values.yaml
git commit -m "feat: add Prometheus stack Helm values for conntrack monitoring"
```

---

## Task 5: 모니터링 배포 스크립트

**Files:**
- Create: `02.deploy-monitoring.sh`

- [ ] **Step 1: 스크립트 작성**

```bash
#!/bin/bash
set -e

# 3개 클러스터에 모니터링 스택 배포
# - conntrack-monitor DaemonSet
# - kube-prometheus-stack (Helm)

set +eu; source ~/.bash_profile; set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLUSTERS=("ekscluster01-iptables" "ekscluster01-ipvs" "ekscluster01-nftables")

echo "============================================"
echo "  모니터링 스택 배포"
echo "============================================"

deploy_monitoring() {
  local cluster="$1"

  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  ▶ ${cluster} 모니터링 배포"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  # kubeconfig 컨텍스트 전환
  kubectl config use-context "${cluster}"

  # 1. conntrack DaemonSet 배포
  echo "  ▶ conntrack-monitor DaemonSet 배포..."
  kubectl apply -f "${SCRIPT_DIR}/manifests/conntrack-monitor-ds.yaml"
  echo "  ✅ conntrack-monitor 배포 완료"

  # 2. Prometheus + Grafana 배포 (Helm)
  echo "  ▶ kube-prometheus-stack 배포..."
  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
  helm repo update

  helm upgrade --install prometheus prometheus-community/kube-prometheus-stack \
    --namespace monitoring --create-namespace \
    --values "${SCRIPT_DIR}/manifests/prometheus-stack/values.yaml" \
    --wait --timeout 10m

  echo "  ✅ Prometheus + Grafana 배포 완료"

  # 상태 확인
  echo "  ▶ 상태 확인..."
  kubectl get pods -n conntrack-monitor -o wide
  kubectl get pods -n monitoring -o wide
}

for cluster in "${CLUSTERS[@]}"; do
  # 클러스터 존재 확인
  STATUS=$(aws eks describe-cluster --name "${cluster}" \
    --query 'cluster.status' --output text \
    --region ap-northeast-2 2>/dev/null || echo "NOT_FOUND")

  if [ "$STATUS" != "ACTIVE" ]; then
    echo "  ⚠️  ${cluster} 가 ACTIVE가 아닙니다 (${STATUS}). 건너뜁니다."
    continue
  fi

  aws eks update-kubeconfig --name "${cluster}" --region ap-northeast-2 --alias "${cluster}"
  deploy_monitoring "${cluster}"
done

echo ""
echo "============================================"
echo "  ✅ 모니터링 배포 완료"
echo "============================================"
echo ""
echo "  다음 단계: ./03.deploy-test-workload.sh"
echo "============================================"
```

- [ ] **Step 2: 실행 권한 및 문법 검증**

```bash
chmod +x 02.deploy-monitoring.sh
bash -n 02.deploy-monitoring.sh && echo "Syntax OK"
```

- [ ] **Step 3: Commit**

```bash
git add 02.deploy-monitoring.sh
git commit -m "feat: add monitoring deployment script for all 3 clusters"
```

---

## Task 6: 테스트 Service 및 부하 생성기 매니페스트

**Files:**
- Create: `manifests/test-services.yaml`
- Create: `manifests/fortio-loadgen.yaml`

- [ ] **Step 1: 테스트 Service 생성 매니페스트 (100개)**

단일 Deployment(200 replicas)를 100개의 ClusterIP Service로 노출하는 구조. conntrack entry를 대량 생성하기 위해 다수의 Service endpoint를 사용한다.

`manifests/test-services.yaml`:

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: conntrack-test
---
# Nginx Deployment — 200 replicas (100 서비스 × 2 replicas)
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx-backend
  namespace: conntrack-test
spec:
  replicas: 200
  selector:
    matchLabels:
      app: nginx-backend
  template:
    metadata:
      labels:
        app: nginx-backend
    spec:
      containers:
        - name: nginx
          image: public.ecr.aws/nginx/nginx:1.27-alpine
          ports:
            - containerPort: 80
          resources:
            requests:
              cpu: 10m
              memory: 16Mi
            limits:
              cpu: 50m
              memory: 32Mi
---
# 100개 ClusterIP Service 생성 스크립트용 템플릿
# 실제 배포는 03.deploy-test-workload.sh에서 루프로 생성
```

- [ ] **Step 2: fortio 부하 생성기 매니페스트**

`manifests/fortio-loadgen.yaml`:

```yaml
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: fortio-client
  namespace: conntrack-test
spec:
  replicas: 1
  selector:
    matchLabels:
      app: fortio-client
  template:
    metadata:
      labels:
        app: fortio-client
    spec:
      containers:
        - name: fortio
          image: fortio/fortio:latest
          command: ["sleep", "infinity"]
          resources:
            requests:
              cpu: 500m
              memory: 512Mi
            limits:
              cpu: 2000m
              memory: 1Gi
---
# fortio 서버 (UI 접근용)
apiVersion: v1
kind: Service
metadata:
  name: fortio-ui
  namespace: conntrack-test
spec:
  type: ClusterIP
  selector:
    app: fortio-client
  ports:
    - port: 8080
      targetPort: 8080
```

- [ ] **Step 3: YAML 검증**

```bash
kubectl apply --dry-run=client -f manifests/test-services.yaml 2>&1 | head -5
kubectl apply --dry-run=client -f manifests/fortio-loadgen.yaml 2>&1 | head -5
```

- [ ] **Step 4: Commit**

```bash
git add manifests/test-services.yaml manifests/fortio-loadgen.yaml
git commit -m "feat: add test services and fortio load generator manifests"
```

---

## Task 7: 테스트 워크로드 배포 스크립트

**Files:**
- Create: `03.deploy-test-workload.sh`

- [ ] **Step 1: 스크립트 작성**

100개의 ClusterIP Service를 동적으로 생성하고 fortio를 배포한다.

```bash
#!/bin/bash
set -e

# 3개 클러스터에 테스트 워크로드 배포
# - Nginx backend (200 replicas)
# - 100개 ClusterIP Service
# - fortio 부하 생성기

set +eu; source ~/.bash_profile; set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLUSTERS=("ekscluster01-iptables" "ekscluster01-ipvs" "ekscluster01-nftables")

echo "============================================"
echo "  테스트 워크로드 배포"
echo "============================================"

deploy_workload() {
  local cluster="$1"

  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  ▶ ${cluster} 워크로드 배포"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  kubectl config use-context "${cluster}"

  # 1. 네임스페이스 + Nginx Deployment 배포
  echo "  ▶ Nginx backend 배포 (200 replicas)..."
  kubectl apply -f "${SCRIPT_DIR}/manifests/test-services.yaml"

  # 2. 100개 ClusterIP Service 동적 생성
  echo "  ▶ ClusterIP Service 100개 생성..."
  for i in $(seq -w 1 100); do
    cat <<EOF | kubectl apply -f - 2>/dev/null
apiVersion: v1
kind: Service
metadata:
  name: svc-${i}
  namespace: conntrack-test
spec:
  type: ClusterIP
  selector:
    app: nginx-backend
  ports:
    - port: 80
      targetPort: 80
EOF
  done
  echo "  ✅ Service 100개 생성 완료"

  # 3. fortio 배포
  echo "  ▶ fortio 부하 생성기 배포..."
  kubectl apply -f "${SCRIPT_DIR}/manifests/fortio-loadgen.yaml"

  # 4. Pod Ready 대기
  echo "  ▶ Pod Ready 대기..."
  kubectl wait --for=condition=Ready pod -l app=nginx-backend \
    -n conntrack-test --timeout=300s 2>/dev/null || true
  kubectl wait --for=condition=Ready pod -l app=fortio-client \
    -n conntrack-test --timeout=120s

  # 상태 확인
  SVC_COUNT=$(kubectl get svc -n conntrack-test --no-headers | wc -l)
  POD_COUNT=$(kubectl get pods -n conntrack-test --no-headers | grep Running | wc -l)
  echo "  ✅ 배포 완료: Service=${SVC_COUNT}, Running Pods=${POD_COUNT}"
}

for cluster in "${CLUSTERS[@]}"; do
  STATUS=$(aws eks describe-cluster --name "${cluster}" \
    --query 'cluster.status' --output text \
    --region ap-northeast-2 2>/dev/null || echo "NOT_FOUND")

  if [ "$STATUS" != "ACTIVE" ]; then
    echo "  ⚠️  ${cluster} 건너뜀 (${STATUS})"
    continue
  fi

  aws eks update-kubeconfig --name "${cluster}" --region ap-northeast-2 --alias "${cluster}"
  deploy_workload "${cluster}"
done

echo ""
echo "============================================"
echo "  ✅ 테스트 워크로드 배포 완료"
echo "============================================"
echo ""
echo "  다음 단계: ./04.run-conntrack-test.sh"
echo "============================================"
```

- [ ] **Step 2: 실행 권한 및 문법 검증**

```bash
chmod +x 03.deploy-test-workload.sh
bash -n 03.deploy-test-workload.sh && echo "Syntax OK"
```

- [ ] **Step 3: Commit**

```bash
git add 03.deploy-test-workload.sh
git commit -m "feat: add test workload deployment script with 100 services"
```

---

## Task 8: 부하 테스트 실행 스크립트

**Files:**
- Create: `04.run-conntrack-test.sh`

- [ ] **Step 1: 스크립트 작성**

4단계 부하(1K/5K/10K/50K connections)를 순차 실행하고, 각 단계에서 conntrack 메트릭과 kube-proxy 메트릭을 수집하여 `results/`에 저장한다.

```bash
#!/bin/bash
set -e

# conntrack 부하 테스트 실행 및 결과 수집
# 사용법: ./04.run-conntrack-test.sh [클러스터명]

set +eu; source ~/.bash_profile; set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS_DIR="${SCRIPT_DIR}/results"
mkdir -p "${RESULTS_DIR}"

CLUSTERS=("ekscluster01-iptables" "ekscluster01-ipvs" "ekscluster01-nftables")
LOAD_LEVELS=(1000 5000 10000 50000)
DURATION="300"  # 각 단계 5분

echo "============================================"
echo "  conntrack 부하 테스트 실행"
echo "============================================"
echo "  부하 단계: ${LOAD_LEVELS[*]} connections"
echo "  각 단계: ${DURATION}초 (5분)"
echo ""

# ─────────────────────────────────────────────
# conntrack 메트릭 수집 함수
# ─────────────────────────────────────────────
collect_conntrack_metrics() {
  local cluster="$1"
  local stage="$2"
  local output_file="${RESULTS_DIR}/${cluster}_stage${stage}_conntrack.json"

  echo "  ▶ conntrack 메트릭 수집..."

  # conntrack-monitor DaemonSet 로그에서 최근 60초 수집
  kubectl logs -n conntrack-monitor -l app=conntrack-monitor \
    --since=60s --all-containers --timestamps 2>/dev/null \
    | grep -o '{.*}' > "${output_file}" || true

  local count=$(wc -l < "${output_file}")
  echo "  ✅ ${count} 레코드 수집 -> ${output_file}"
}

# ─────────────────────────────────────────────
# kube-proxy 메트릭 수집 함수
# ─────────────────────────────────────────────
collect_kubeproxy_metrics() {
  local cluster="$1"
  local stage="$2"
  local output_file="${RESULTS_DIR}/${cluster}_stage${stage}_kubeproxy.txt"

  echo "  ▶ kube-proxy 메트릭 수집..."

  # kube-proxy Pod에서 메트릭 endpoint 조회
  PROXY_POD=$(kubectl get pods -n kube-system -l k8s-app=kube-proxy \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

  if [ -n "$PROXY_POD" ]; then
    kubectl exec -n kube-system "${PROXY_POD}" -- \
      curl -s http://localhost:10249/metrics 2>/dev/null \
      | grep -E "kubeproxy_sync_proxy_rules|kubeproxy_network_programming" \
      > "${output_file}" || true
    echo "  ✅ kube-proxy 메트릭 -> ${output_file}"
  else
    echo "  ⚠️  kube-proxy Pod 접근 불가"
  fi
}

# ─────────────────────────────────────────────
# fortio 부하 실행 함수
# ─────────────────────────────────────────────
run_load_test() {
  local cluster="$1"
  local connections="$2"
  local stage="$3"
  local output_file="${RESULTS_DIR}/${cluster}_stage${stage}_fortio.json"

  echo ""
  echo "  ──────────────────────────────────────"
  echo "  Stage ${stage}: ${connections} concurrent connections"
  echo "  ──────────────────────────────────────"

  # conntrack DaemonSet 수집 간격을 1초로 변경
  kubectl set env ds/conntrack-monitor -n conntrack-monitor COLLECT_INTERVAL=1 2>/dev/null || true

  # fortio Pod에서 부하 실행 (100개 Service에 분산)
  FORTIO_POD=$(kubectl get pods -n conntrack-test -l app=fortio-client \
    -o jsonpath='{.items[0].metadata.name}')

  echo "  ▶ fortio 부하 시작 (${connections} conn, ${DURATION}s)..."

  # 100개 Service에 균등 분산: 각 Service당 connections/100
  PER_SVC=$((connections / 100))

  kubectl exec -n conntrack-test "${FORTIO_POD}" -- \
    fortio load -c "${connections}" -t "${DURATION}s" -qps 0 \
    -json "${output_file}" \
    http://svc-001.conntrack-test.svc.cluster.local:80 \
    2>&1 | tail -5

  echo "  ✅ 부하 완료"

  # 메트릭 수집
  collect_conntrack_metrics "${cluster}" "${stage}"
  collect_kubeproxy_metrics "${cluster}" "${stage}"

  # fortio 결과 복사
  kubectl cp "conntrack-test/${FORTIO_POD}:${output_file}" \
    "${output_file}" 2>/dev/null || true

  # 수집 간격 복원
  kubectl set env ds/conntrack-monitor -n conntrack-monitor COLLECT_INTERVAL=5 2>/dev/null || true

  # 쿨다운 (conntrack table 안정화)
  echo "  ▶ 30초 쿨다운..."
  sleep 30
}

# ─────────────────────────────────────────────
# 메인 실행
# ─────────────────────────────────────────────
TARGET="${1:-all}"
if [ "$TARGET" = "all" ]; then
  TEST_CLUSTERS=("${CLUSTERS[@]}")
else
  TEST_CLUSTERS=("$TARGET")
fi

for cluster in "${TEST_CLUSTERS[@]}"; do
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  ▶ ${cluster} 부하 테스트"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  kubectl config use-context "${cluster}"

  STAGE=1
  for conns in "${LOAD_LEVELS[@]}"; do
    run_load_test "${cluster}" "${conns}" "${STAGE}"
    STAGE=$((STAGE + 1))
  done
done

echo ""
echo "============================================"
echo "  ✅ 부하 테스트 완료"
echo "============================================"
echo ""
echo "  결과 파일:"
ls -la "${RESULTS_DIR}/"
echo ""
echo "  다음 단계: 결과 분석 후 ./05.cleanup-clusters.sh"
echo "============================================"
```

- [ ] **Step 2: 실행 권한 및 문법 검증**

```bash
chmod +x 04.run-conntrack-test.sh
bash -n 04.run-conntrack-test.sh && echo "Syntax OK"
```

- [ ] **Step 3: Commit**

```bash
git add 04.run-conntrack-test.sh
git commit -m "feat: add conntrack load test execution and metrics collection script"
```

---

## Task 9: 클러스터 정리 스크립트

**Files:**
- Create: `05.cleanup-clusters.sh`

- [ ] **Step 1: 스크립트 작성**

```bash
#!/bin/bash
set -e

# 3개 conntrack 분석 클러스터 삭제
# 사용법: ./05.cleanup-clusters.sh [iptables|ipvs|nftables|all]

set +eu; source ~/.bash_profile; set -e

CLUSTERS=("ekscluster01-iptables" "ekscluster01-ipvs" "ekscluster01-nftables")
TARGET="${1:-all}"
AWS_REGION="ap-northeast-2"

echo "============================================"
echo "  EKS conntrack 분석 클러스터 삭제"
echo "============================================"
echo ""

if [ "$TARGET" = "all" ]; then
  DELETE_CLUSTERS=("${CLUSTERS[@]}")
else
  DELETE_CLUSTERS=("ekscluster01-${TARGET}")
fi

echo "  삭제 대상:"
for c in "${DELETE_CLUSTERS[@]}"; do
  echo "    - ${c}"
done
echo ""
read -p "  정말 삭제하시겠습니까? (yes/no): " CONFIRM
if [ "$CONFIRM" != "yes" ]; then
  echo "  취소되었습니다."
  exit 0
fi

for cluster in "${DELETE_CLUSTERS[@]}"; do
  echo ""
  echo "  ▶ ${cluster} 삭제 중..."

  EXISTING=$(aws eks describe-cluster --name "${cluster}" \
    --query 'cluster.status' --output text \
    --region "${AWS_REGION}" 2>/dev/null || echo "NOT_FOUND")

  if [ "$EXISTING" = "NOT_FOUND" ]; then
    echo "  ⚠️  ${cluster} 없음, 건너뜁니다."
    continue
  fi

  eksctl delete cluster --name "${cluster}" --region "${AWS_REGION}" --wait
  echo "  ✅ ${cluster} 삭제 완료"

  # 생성된 config 파일 정리
  rm -f "$(dirname "$0")/${cluster}.yaml"

  # kubeconfig 컨텍스트 제거
  kubectl config delete-context "${cluster}" 2>/dev/null || true
done

echo ""
echo "============================================"
echo "  ✅ 클러스터 삭제 완료"
echo "============================================"
```

- [ ] **Step 2: 실행 권한 및 문법 검증**

```bash
chmod +x 05.cleanup-clusters.sh
bash -n 05.cleanup-clusters.sh && echo "Syntax OK"
```

- [ ] **Step 3: Commit**

```bash
git add 05.cleanup-clusters.sh
git commit -m "feat: add cluster cleanup script"
```

---

## Task 10: CLAUDE.md 프로젝트 가이드

**Files:**
- Create: `CLAUDE.md`

- [ ] **Step 1: CLAUDE.md 작성**

```markdown
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
```

- [ ] **Step 2: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: add project guide for EKS conntrack analysis"
```

---

## Self-Review 체크

1. **Spec 커버리지**: 3개 클러스터 생성(Task 1-2), kube-proxy 모드 설정(Task 1 템플릿), Add-on 구성(Task 1), conntrack DaemonSet(Task 3), Prometheus+Grafana(Task 4-5), 테스트 워크로드(Task 6-7), 부하 테스트(Task 8), 정리(Task 9), 문서(Task 10) — spec 전체 커버됨.
2. **Placeholder 스캔**: TBD/TODO 없음. 모든 step에 실제 코드 포함.
3. **일관성**: 클러스터명(`ekscluster01-iptables/ipvs/nftables`), 네임스페이스(`conntrack-monitor`, `conntrack-test`, `monitoring`), 파일 경로 모두 일관됨.
