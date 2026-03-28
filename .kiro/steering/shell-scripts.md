# Shell Script 규칙

- 모든 스크립트는 `set -e`로 시작하여 에러 시 즉시 중단
- `~/.bash_profile` 소싱 후 실행 (AWS 자격증명, eksctl 경로 등)
- 변수는 `${VAR}` 형식으로 중괄호 사용
- 에러 메시지는 stderr로 출력 (`>&2`)
- 정리(cleanup) 로직은 trap으로 구현
- 스크립트 재실행 시 안전하도록 멱등성 보장
- 반복 패턴은 함수로 추출하여 DRY 원칙 준수
