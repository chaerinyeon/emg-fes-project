# assets/web/

관찰 화면(`monitor.html`)이 들어갈 자리. `MonitorBroadcaster` 가
`rootBundle.loadString('assets/web/monitor.html')` 로 이 디렉터리의 파일을
그대로 서빙한다.

`monitor.html` 자체는 다음 태스크에서 만든다 — 이 디렉터리는 `pubspec.yaml`
의 `assets:` 등록이 빌드에서 유효하도록(에셋 디렉터리가 실제로 존재하도록)
자리만 잡아 둔 것이다.
