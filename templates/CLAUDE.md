# templates/

eksctl 클러스터 설정 YAML 템플릿.

- `eksctl-cluster.yaml.tpl` — envsubst 변수로 클러스터명, kube-proxy 모드, 노드그룹명을 주입
- 01.create-clusters.sh에서 사용

변수: `${CLUSTER_NAME}`, `${PROXY_MODE}`, `${NODEGROUP_NAME}`, `${PROXY_CONFIG_VALUES}`
