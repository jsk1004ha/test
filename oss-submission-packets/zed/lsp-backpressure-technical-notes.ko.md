# Zed 제안 개요 — LSP I/O backlog에 bounded backpressure 적용

> **AI-assisted technical notes — upstream에 그대로 제출하지 마세요.** Zed는 큰 기능을 먼저 Discussion에서 합의하도록 요구하며, 자율 에이전트가 작성·제출한 기여를 받지 않습니다. 아래 자료를 이해한 뒤 본인의 재현 경험·판단·표현으로 다시 작성해야 합니다.

## 한 문장 제안

Language server I/O를 UI/main-thread 소비자에게 전달하는 unbounded channel에 메모리 상한과 과부하 정책을 도입해, 느리거나 멈춘 소비자와 chatty/misbehaving LSP 사이에 자원 격리를 만든다.

## 현재 코드에서 확인되는 사실

- 최종 화면 log/trace deque는 entry 수가 제한돼 있습니다.
- pending RPC request tracker에도 entry 상한이 있습니다.
- 그러나 producer→consumer 경로는 `mpsc::unbounded()`입니다.
- LSP I/O callback은 각 message를 `String`으로 복사한 뒤 `unbounded_send()`합니다.
- 따라서 소비자가 처리하기 전 backlog에는 별도 message·byte 상한이 없습니다.

이것은 “현재 확인된 위험 경계”입니다. 특정 대규모 메모리 사고의 원인이라고 단정해서는 안 됩니다.

## 문제 정의

다음 조건이 겹치면 backlog가 지속적으로 증가할 수 있습니다.

1. language server가 stderr/RPC를 빠르게 출력
2. main thread 또는 `LogStore` update 처리 지연
3. producer가 blocking/backpressure 없이 계속 enqueue
4. 최종 deque의 제한은 소비 이후에만 적용되므로 ingress backlog에는 효과 없음

원하는 invariant:

> 외부 language server와 UI 지연이 결합해도 Zed process의 LSP log ingress 메모리는 명시된 범위를 넘지 않는다.

## 제안할 설계 선택지

### A. 고정 message-count bounded channel

장점:
- 구현이 작고 이해하기 쉬움

단점:
- 20바이트 message와 20MB message를 동일하게 취급
- 실제 메모리 경계가 아님

### B. byte-budgeted bounded ingress — 권장

구성:
- queue entry마다 `message.len()`을 accounting
- 전체 global budget + 선택적 per-server budget
- 소비 완료 시 budget 반환
- budget 초과 시 명시적 overflow policy 적용

예시 초기값은 Discussion에서 합의:
- global 8–32 MiB
- per-server 2–8 MiB

숫자는 benchmark·실제 log 분포 없이 확정하지 않음.

### C. pull/permit 기반 backpressure

producer가 permit을 얻어야 String을 queue에 넣도록 함.

주의:
- LSP stdout/stderr read loop를 오래 block하면 language server 자체가 pipe backpressure로 멈출 수 있음
- protocol response 처리와 단순 log 표시 경로를 분리해야 함

## 권장 overflow 정책

RPC protocol traffic과 display-only logs를 동일하게 버리면 안 됩니다.

- **프로토콜 요청·응답:** correctness에 필요한 경로라면 drop 금지. 별도 processing path 또는 제한된 blocking 필요.
- **stderr/log notifications:** 가장 오래된 low-severity entry drop 또는 동일 line coalescing.
- **ERROR/WARN:** 가능한 한 우선 보존.
- overflow가 발생한 뒤 consumer가 회복되면 synthetic entry 추가:
  - dropped messages
  - dropped bytes
  - server ID/name
  - overflow 시작·종료 시각

## per-server isolation

한 language server가 budget 전체를 독점하지 않도록:

- global budget
- per-server soft/hard budget
- round-robin drain 또는 producer별 queue
- server 종료 시 남은 accounting 정리

## 관측성

- 현재 queued bytes/messages
- high-water mark
- dropped/coalesced bytes/messages
- server별 overflow count
- consumer lag 또는 oldest-entry age

사용자 telemetry 전송 여부와 무관하게 debug diagnostics에서 확인 가능해야 함.

## 테스트 계획

1. consumer를 의도적으로 멈추고 대량 log를 보내도 byte budget을 넘지 않음
2. 한 server의 flood가 다른 server의 ERROR message를 완전히 밀어내지 않음
3. 동일 stderr line coalescing
4. server 제거 시 queue·byte accounting 회수
5. consumer 회복 후 dropped summary 정확성
6. RPC timing tracker가 log drop으로 깨지지 않음
7. remote/headless project 경로
8. shutdown/drop race에서 panic·leak 없음

## 성능 검증

- 정상 부하에서 현재 unbounded channel 대비 overhead
- 1KB/64KB/1MB message 분포
- 1·4·16개 language server
- stalled consumer 1초/10초
- allocations/message와 peak RSS

## 유지관리자에게 먼저 묻고 싶은 결정

1. `LogStore` ingress만 범위로 잡아도 되는가, 아니면 core LSP RPC reader에 더 낮은 계층의 backpressure가 필요한가?
2. drop 가능한 것은 stderr/log notification뿐인가?
3. global/per-server budget을 setting으로 노출할지 내부 상수로 시작할지?
4. overflow 때 oldest-drop, newest-drop, severity-aware drop 중 어떤 UX가 맞는가?
5. 관련 메모리 사고를 추적하기 위해 먼저 instrumentation-only PR을 선호하는가?

## 작은 1단계 대안

유지관리자가 큰 변경을 원하지 않으면 첫 PR을 다음으로 제한:

- queue byte high-water instrumentation
- oldest-entry age
- server별 enqueue rate
- overflow를 발생시키지 않는 debug diagnostics

실측 후 두 번째 PR에서 budget과 정책 도입.
