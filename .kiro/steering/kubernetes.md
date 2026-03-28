# Kubernetes 매니페스트 규칙

- DaemonSet은 hostNetwork + privileged로 노드 메트릭 접근
- conntrack-monitor는 `/host/proc/sys`로 마운트 (containerd 보안 제한)
- 리소스 limits/requests 반드시 명시
- securityContext 명시 (privileged 필요 시 명확히 주석)
- label은 `app: <name>` 형식으로 일관성 유지
- Prometheus storageClass: gp2
- 네임스페이스: conntrack-test (워크로드), conntrack-monitor (모니터링), monitoring (Prometheus)
