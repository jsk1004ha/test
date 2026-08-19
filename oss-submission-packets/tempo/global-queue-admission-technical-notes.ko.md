# Grafana Tempo 제안 개요 — Query frontend global queue admission limits

> **AI-assisted technical notes — upstream 이슈에 그대로 제출하지 마세요.** Tempo는 비단순 변경을 먼저 이슈에서 논의하도록 요구하고, AI가 이슈·PR 설명을 대신 작성하는 것을 원하지 않습니다. 아래 내용을 검토한 뒤 본인의 말과 판단으로 다시 작성해야 합니다.

## 한 문장 제안

기존 tenant별 query queue 상한은 유지하면서, frontend process 전체의 outstanding request 수와 active tenant queue 수에도 선택적 상한을 추가해 tenant-cardinality 폭증과 process-wide memory exhaustion을 방지한다.

## 현재 코드에서 확인되는 사실

- 각 tenant queue의 channel capacity는 `max_outstanding_per_tenant`로 제한됩니다.
- 새 tenant ID가 들어오면 map entry와 같은 크기의 buffered channel을 생성합니다.
- 모든 tenant를 합친 outstanding request 수에는 별도 상한이 없습니다.
- 동시에 존재할 수 있는 nonempty tenant queue 수에도 별도 상한이 없습니다.
- `0`이나 합리적인 기본값을 정하는 public configuration 논의가 필요합니다.

예시:
- tenant별 상한이 2,000
- 10,000개의 서로 다른 tenant ID가 각 1건씩 enqueue
- tenant별 제한은 모두 지키지만 active queue cardinality와 process 전체 request 수는 계속 증가

이것은 보안 취약점 단정이 아니라 multi-tenant admission-control gap입니다.

## 제안 설정

초기 PR에서는 backward compatibility를 위해 `0 = unlimited`:

```yaml
query_frontend:
  max_outstanding_requests_per_tenant: 2000
  max_outstanding_requests_total: 0
  max_active_tenant_queues: 0
```

실제 YAML 계층과 flag 이름은 현재 Tempo naming convention에 맞춰 유지관리자와 확정.

후보 flags:

```text
querier.max-outstanding-requests-total
querier.max-active-tenant-queues
```

## admission 순서

enqueue lock 안에서 원자적으로:

1. queue stopped 여부
2. 기존 tenant queue인지 확인
3. 새 tenant라면 active-tenant cap 예약
4. global outstanding slot 예약
5. tenant queue 생성 또는 조회
6. nonblocking enqueue
7. 실패 시 모든 예약 rollback
8. 성공 시 metric·condition update

핵심 invariant:

- 성공한 enqueue마다 global count +1
- dequeue마다 정확히 -1
- 실패한 enqueue는 net 0
- active tenant count는 map의 실제 nonempty queue cardinality와 일치
- count가 음수가 되거나 cap을 초과하지 않음

## 오류 표면

기존 caller compatibility를 위해 외부에는 우선 `ErrTooManyRequests`를 유지할 수 있습니다.

내부 원인 구분:

- per-tenant limit
- global request limit
- active tenant limit

HTTP 표면은 모두 429를 유지하되 metrics/logs에서 reason 구분.

## metrics

- `tempo_query_frontend_outstanding_requests`
- `tempo_query_frontend_active_tenant_queues`
- `tempo_query_frontend_admission_rejections_total{reason=...}`
- optional high-water metrics

기존 tenant-label metrics와 달리 global metrics에는 tenant label을 넣지 않아 cardinality를 늘리지 않음.

## 첫 PR에 포함하지 않을 것

- request byte-size 추정
- `Request.Weight()` 기반 memory accounting
- tenant 우선순위
- 동적 per-tenant override
- distributed/global-across-replicas limit

`Weight()`는 batch scheduling 의미이므로 메모리 크기와 동일하다고 가정하지 않음.

## 테스트 계획

1. **기존 동작:** 두 global 설정이 0이면 기존 unlimited 동작 유지
2. **cross-tenant total cap:** 여러 tenant의 합이 total cap을 넘으면 거부
3. **active tenant cap:** 새 tenant만 거부하고 기존 tenant는 자신의 per-tenant·global 여유 안에서 enqueue 가능
4. **dequeue release:** dequeue 후 global slot 재사용
5. **empty queue cleanup:** tenant queue 제거 후 새 tenant admission 가능
6. **rollback:** tenant full, queue creation failure, nonblocking send failure 후 count 원복
7. **concurrency:** 수백 goroutine enqueue에서도 observed maximum이 cap 이하
8. **shutdown/drain:** stop 과정에서 count가 음수가 되지 않고 pending request semantics 유지
9. **race detector:** queue package tests with `-race`
10. **metrics:** rejection reason과 gauges 정확성

## 구현 범위 예상

변경 후보:

- `modules/frontend/v1/frontend.go`
  - config/flags
  - global gauges/counter
  - queue constructor wiring
- `modules/frontend/queue/queue.go`
  - admission counters와 rollback
- `modules/frontend/queue/user_queues.go`
  - existing/new queue 구분 API 또는 active queue count
- `modules/frontend/queue/queue_test.go`
  - 위 회귀·동시성 테스트
- generated configuration docs/changelog if required

## 유지관리자에게 묻고 싶은 결정

1. V1 frontend queue에만 적용할지 scheduler 경로까지 공통화할지?
2. `0 = unlimited`로 시작할지 안전한 finite default를 둘지?
3. total request cap과 tenant cardinality cap을 한 PR에 넣을지 분리할지?
4. rejection reason을 public error type으로 노출할지 metrics에만 둘지?
5. Loki/Mimir의 newer queue package와 장기적으로 공통화할 계획이 있는지?

## 더 작은 1단계 대안

먼저 behavior change 없이 다음만 추가:

- total outstanding request gauge
- active tenant queue gauge
- high-water instrumentation

운영 데이터로 적정 기본값을 확인한 뒤 admission limit PR 제출.
