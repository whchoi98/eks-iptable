# results/

테스트 결과 데이터 및 분석 보고서.

## 파일 네이밍

- `{클러스터}_stage{N}_conntrack.json` — conntrack 메트릭 (JSON)
- `{클러스터}_stage{N}_kubeproxy.txt` — kube-proxy 메트릭
- `{클러스터}_kubeproxy_full.txt` — 전체 노드 kube-proxy 메트릭 (curl debug pod 수집)
- `{클러스터}_scaleout_sync.txt` — 노드 스케일아웃 kube-proxy sync 결과
- `analysis-report.md` — 종합 분석 보고서
