# eksctl 클러스터 규칙

- 템플릿은 `templates/eksctl-cluster.yaml.tpl`에서 envsubst로 변수 주입
- 변수: `${CLUSTER_NAME}`, `${PROXY_MODE}`, `${NODEGROUP_NAME}`, `${PROXY_CONFIG_VALUES}`
- 클러스터 컨텍스트명은 클러스터명과 동일하게 설정 (`--alias`)
- API Endpoint: private only (endpointPublicAccess: false)
- 동일 VPC (vpc-0151a6dcd10c1c738), private subnet only
- 노드: m6g.xlarge (Graviton ARM64), AL2023, 50GiB gp3 encrypted
- VPC 엔드포인트 SG에 모든 클러스터 SG 추가 필요
