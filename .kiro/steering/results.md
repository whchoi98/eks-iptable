# 결과 데이터 규칙

- 결과 파일은 `results/` 디렉토리에 저장
- 네이밍: `{클러스터}_{stage}_{타입}.{ext}` 형식
  - `{클러스터}_stage{N}_conntrack.json` — conntrack 메트릭
  - `{클러스터}_stage{N}_kubeproxy.txt` — kube-proxy 메트릭
  - `{클러스터}_kubeproxy_full.txt` — 전체 노드 kube-proxy 메트릭
  - `{클러스터}_scaleout_sync.txt` — 노드 스케일아웃 sync 결과
- `analysis-report.md` — 종합 분석 보고서 (3개 모드 비교)
- 분석 보고서 작성 시 반드시 수치 근거 포함 (테이블, ASCII 차트)
