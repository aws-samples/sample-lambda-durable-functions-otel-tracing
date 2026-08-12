# Tracing AWS Lambda Durable Functions with OpenTelemetry

A minimal, deployable AWS SAM sample that instruments a **Lambda durable function** with the [OpenTelemetry plugin for the AWS Durable Execution SDK](https://pypi.org/project/aws-durable-execution-sdk-python-otel/) (`aws-durable-execution-sdk-python-otel`). It shows how a single durable execution that spans **multiple Lambda invocations** is unified into **one distributed trace**, with per-operation spans and automatically correlated logs.

This is the companion code for the AWS blog post *"Observability for durable workflows: tracing AWS Lambda durable functions with OpenTelemetry."*

## Why tracing for durable functions?

Durable functions build resilient, multi-step workflows that checkpoint progress and recover from failures through replay. A single execution can suspend (e.g., waiting on a human approval) and resume **hours or days later** in a brand-new Lambda invocation. By default each invocation emits its own trace, so the end-to-end view of one logical workflow is **fragmented** across disconnected traces — forcing operators to stitch signals together by hand.

The OTel plugin derives a **deterministic trace ID** from the X-Ray header, so every invocation of the same execution shares one trace. Each `step`, `wait`, and `wait_for_callback` becomes its own span, and every log record is stamped with `traceId` / `spanId`.

## Overview

The sample deploys a document-review workflow with a human-approval gate:

```
extract-text (1s) → summarize (2s) → human-review (wait_for_callback) → publish (0.5s)
```

The execution runs across **at least two Lambda invocations**: the first runs `extract-text` and `summarize` then suspends at `human-review` (zero compute cost while waiting); when the callback arrives, Lambda invokes the function again, replays the completed steps, and runs `publish`. With the plugin, both invocations appear under a **single unified trace**.

## Project Structure

```
SourceCode/
├── README.md                    # This file
├── LICENSE                      # MIT-0
├── CONTRIBUTING.md              # Contribution + security-reporting guidelines
├── template.yaml                # SAM template (IaC): function, X-Ray, ADOT layer, alias
├── samconfig.toml               # SAM deploy config (region us-east-1, stack "durable-otel")
├── src/
│   ├── index.py                 # Durable handler instrumented with OtelPlugin()
│   └── requirements.txt         # aws-durable-execution-sdk-python[-otel]
└── test/
    └── run-evidence-test.sh     # End-to-end test that also collects reviewable evidence
```

## Prerequisites

- **Python >= 3.11**
- **[AWS SAM CLI](https://docs.aws.amazon.com/serverless-application-model/latest/developerguide/install-sam-cli.html)**
- **[AWS CLI v2](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html)**, configured with credentials
- An AWS account with permissions to create Lambda functions, enable X-Ray active tracing, add Lambda layers, and write CloudWatch Logs

> **Note:** `samconfig.toml` pins the deployment to **us-east-1**. If your shell environment resolves the AWS CLI to a different region (via `AWS_REGION` / `AWS_DEFAULT_REGION`), pass `--region us-east-1` explicitly to the `aws` commands, or the runtime test steps will target the wrong region.

## Quick Start

### Build

```bash
sam build
```

### Deploy

```bash
sam deploy
```

The template uses `AutoPublishAlias: live`, so **versioning is managed by CloudFormation/SAM** — each deploy publishes a new Lambda version and points the `live` alias at it. Durable functions require a qualified ARN (not `$LATEST`); the `live` alias provides a stable qualifier, so **no manual `aws lambda publish-version` step is needed**.

### Test

Run the automated end-to-end test (see [Testing](#testing)):

```bash
./test/run-evidence-test.sh
```

Or exercise the flow manually — invoke asynchronously (the function suspends at `wait_for_callback`, so a synchronous invoke would block):

```bash
aws lambda invoke \
  --function-name durable-otel-sample \
  --qualifier live \
  --region us-east-1 \
  --invocation-type Event \
  --cli-binary-format raw-in-base64-out \
  --payload '{"doc_id": "test-doc-001"}' \
  response.json
```

Read the `callback_id` from the logs and resume the execution:

```bash
# Find the callback_id logged by the handler
aws logs filter-log-events \
  --log-group-name /aws/lambda/durable-otel-sample \
  --region us-east-1 \
  --filter-pattern "CALLBACK ID"

# Resume — note: this command does NOT take --function-name; the callback_id
# already contains the reference to the execution.
aws lambda send-durable-execution-callback-success \
  --region us-east-1 \
  --cli-binary-format raw-in-base64-out \
  --callback-id "<CALLBACK_ID_FROM_LOGS>" \
  --result '{"approved": true, "reviewer": "alice"}'
```

Then open **CloudWatch → Traces** to see the single unified trace.

## Testing

### `test/run-evidence-test.sh`

An end-to-end test that drives the full durable workflow **and collects reviewable evidence** that trace + log collection works. It performs **runtime operations only** (`invoke`, `send-durable-execution-callback-success`) and **mutates no infrastructure** — it verifies the `live` alias exists and, if not, tells you to deploy first.

```bash
./test/run-evidence-test.sh [--wait-review SECONDS]
```

Environment overrides: `FUNCTION_NAME` (default `durable-otel-sample`), `ALIAS` (default `live`), `REGION` (default `us-east-1`), `DOC_ID` (default `test-doc-001`).

The script writes a timestamped evidence package to `test/evidence/<timestamp>/`:

| File | Contents |
|------|----------|
| `EVIDENCE.md` | Human-readable report tying everything together |
| `00-run-metadata.json` | Account, region, function, alias/version, timestamp |
| `01-invoke-response.json` | Async invoke response (`DurableExecutionArn`) |
| `02-callback.json` | Callback ID used and send result |
| `03-xray-trace-summary.json` | The single unified trace summary |
| `04-xray-trace-full.json` | Full trace with all segments/subsegments |
| `05-spans.txt` | Derived span tree (span-per-operation) |
| `06-correlated-logs.json` | Log records carrying this execution's `traceId` |

The generated `EVIDENCE.md` verifies three claims: (1) a **single trace ID** shared by **two distinct Lambda invocations** with total wall-clock `Duration` ≫ compute `Response Time`; (2) **span-per-operation** (`extract-text`, `summarize`, `human-review`, `publish` plus replay/continuation spans); and (3) **log correlation** (`traceId`, `spanId`, `otelTraceSampled` on every record).

### Expected result

A successful run reports a single unified trace and a span tree like the one below (values vary per run):

```
## 1. Single unified trace across invocations
- OTel traceId: 6a7c5d59...            # one id for the whole execution
- Distinct Lambda invocations sharing this trace: 2   ✅
- Trace status OK (no error): ✅
- Duration (wall-clock, incl. human-review wait): 30.6s
- Response Time (compute only): 0.014s  ✅ (compute ≪ wall-clock)

## 2. Span-per-operation           # both invocations, under one trace
- invocation
    - extract-text     (~1.0s)
    - summarize        (~2.0s)
    - human-review     (wait_for_callback)
    - publish          (~0.5s)

## 3. Log correlation
- otelTraceSampled=true on all app records: ✅
```

If instead you see `Named operation spans found: (none)` or all log records sharing one `spanId`, the OpenTelemetry SDK is not being initialized (check that X-Ray active tracing is on and the ADOT layer version matches the plugin version).

## Configuration

### Template settings (`template.yaml`)

| Setting | Value | Purpose |
|---------|-------|---------|
| `Tracing` | `Active` | Enables X-Ray; the plugin derives the deterministic trace ID from `_X_AMZN_TRACE_ID` |
| `Layers` | ADOT Python layer `aws-otel-python-amd64-ver-1-25-0:1` | Exports OTel traces from the function |
| `AWS_LAMBDA_EXEC_WRAPPER` | `/opt/otel-instrument` | ADOT auto-instrumentation entrypoint |
| `DurableConfig.ExecutionTimeout` | `900` | Enables durable mode |
| `AutoPublishAlias` | `live` | IaC-managed version + stable qualified ARN |

> Pin the ADOT layer version in production to avoid unexpected behavior from automatic version changes. See the [ADOT Lambda layer ARNs](https://aws-otel.github.io/docs/getting-started/lambda/lambda-python) for the latest version and architecture.

### Plugin options (not exercised by this sample)

- `OtelPlugin(enrich_logger=False)` — disable automatic log stamping (default `True`)
- `OtelPlugin(context_extractor=w3c_client_context_extractor)` — cross-service W3C context propagation
- Supply a custom `TracerProvider`
- Control trace volume with standard OpenTelemetry sampling (`OTEL_TRACES_SAMPLER`); this sample samples 100%

## Implementation Details

The handler in [`src/index.py`](src/index.py) enables tracing with a single line — `OtelPlugin()` passed to the decorator:

```python
from aws_durable_execution_sdk_python_otel import OtelPlugin

@durable_execution(plugins=[OtelPlugin()])
def handler(event: dict, context: DurableContext) -> dict:
    extracted = context.step(extract_text(event["doc_id"]), name="extract-text")
    summary   = context.step(summarize(extracted), name="summarize")
    approval  = context.wait_for_callback(submitter=submit_for_review, name="human-review")
    ...
    context.step(publish(summary, approval), name="publish")
```

- **Named operations** — each `context.step()` / `context.wait_for_callback()` passes a `name`, which becomes the span name in traces.
- **Small `time.sleep()` calls** in the steps give each span a visible duration in the trace (demo only); they are not required by the plugin.
- **Replay-aware** — during replay, the plugin identifies replayed operations and does not emit duplicate spans; only new operations produce new spans.

## IAM Permissions Required

The function's execution role (see `Policies` in `template.yaml`) grants:

- **`AWSXRayDaemonWriteAccess`** (managed policy) — or the equivalent `xray:PutTraceSegments` and `xray:PutTelemetryRecords` — required to export traces.
- **`lambda:SendDurableExecutionCallbackSuccess`** — for resuming callback-based waits.

## Cost

- The plugin is open source (**Apache 2.0**).
- Costs come from **[AWS X-Ray](https://aws.amazon.com/xray/pricing/)** (~$5.00 per million traces recorded) and the ADOT Lambda layer (~40–60 MB additional memory, ~200–400 ms cold-start overhead).
- **Each durable execution produces one trace regardless of invocation count**, so cost scales with executions, not invocations.

## Cleanup

Delete the SAM CloudFormation stack (removes the function, alias, versions, and role):

```bash
sam delete
```

## Resources

- [AWS Lambda durable functions](https://docs.aws.amazon.com/lambda/latest/dg/durable-functions.html)
- [AWS Durable Execution SDK Developer Guide](https://docs.aws.amazon.com/durable-functions/)
- [`aws-durable-execution-sdk-python-otel` on PyPI](https://pypi.org/project/aws-durable-execution-sdk-python-otel/)
- [AWS Distro for OpenTelemetry (ADOT) — Lambda](https://aws-otel.github.io/docs/getting-started/lambda)
- [OpenTelemetry](https://opentelemetry.io/)

## Security

See [CONTRIBUTING](CONTRIBUTING.md#security-issue-notifications) for more information.

## License

This sample is licensed under the MIT-0 License. See the LICENSE file.
