# manifests/

Kubernetes 매니페스트 파일.

- `conntrack-monitor-ds.yaml` — conntrack 통계 수집 DaemonSet (privileged, hostNetwork)
- `prometheus-stack/values.yaml` — kube-prometheus-stack Helm values (storageClass: gp2)
- `test-services.yaml` — Nginx backend Deployment (180 replicas)
- `fortio-loadgen.yaml` — fortio 부하 생성기 Deployment + Service

주의: conntrack-monitor는 `/host/proc/sys`로 마운트 (containerd 보안 제한).
