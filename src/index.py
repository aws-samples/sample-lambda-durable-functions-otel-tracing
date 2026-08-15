"""
Durable Functions + OpenTelemetry sample handler.

A document-review workflow — extract-text -> summarize -> human-review -> publish
— that suspends at a human-approval callback and resumes in a later Lambda
invocation. Passing ``OtelPlugin()`` to ``@durable_execution`` unifies every
invocation of the execution into a single distributed trace: one span per
durable operation, with ``traceId`` / ``spanId`` stamped on every log record.

See README.md for build, deploy, and test instructions.
"""

import json
import logging
import time

from aws_durable_execution_sdk_python import (
    DurableContext,
    durable_execution,
    durable_step,
)
from aws_durable_execution_sdk_python.types import WaitForCallbackContext
from aws_durable_execution_sdk_python_otel import OtelPlugin

logger = logging.getLogger()
logger.setLevel(logging.INFO)


@durable_step
def extract_text(step_context, doc_id):
    step_context.logger.info(f"Extracting text from document: {doc_id}")
    time.sleep(1.0)  # demo only: gives the span a visible duration in the trace
    return {"doc_id": doc_id, "text": "extracted content"}


@durable_step
def summarize(step_context, extracted):
    step_context.logger.info(f"Summarizing document: {extracted['doc_id']}")
    time.sleep(2.0)  # demo only: gives the span a visible duration in the trace
    return {"summary": "Document summary here"}


@durable_step
def publish(step_context, summary, approval):
    step_context.logger.info(f"Publishing with approval from: {approval.get('reviewer')}")
    time.sleep(0.5)  # demo only: gives the span a visible duration in the trace
    return {"status": "published"}


@durable_execution(plugins=[OtelPlugin()])
def handler(event: dict, context: DurableContext) -> dict:
    extracted = context.step(extract_text(event["doc_id"]), name="extract-text")
    summary = context.step(summarize(extracted), name="summarize")

    def submit_for_review(callback_id: str, ctx: WaitForCallbackContext) -> None:
        # Callback ID is enough to resume — the command does NOT accept --function-name
        logger.info(f"=== CALLBACK ID FOR MANUAL RESUME: {callback_id} ===")
        logger.info("In production the callback ID goes to the approver over")
        logger.info(" an authenticated channel, never to logs, and the")
        logger.info(" approver's identity comes from that channel")
        logger.info(" rather than from a caller-supplied field.")
        logger.info(
            f"aws lambda send-durable-execution-callback-success "
            f"--cli-binary-format raw-in-base64-out "
            f'--callback-id "{callback_id}" '
            f"--result '{{\"approved\": true, \"reviewer\": \"alice\"}}'"
        )

    approval = context.wait_for_callback(submitter=submit_for_review, name="human-review")
    # SDK returns result as JSON string — parse it
    if isinstance(approval, str):
        approval = json.loads(approval)

    if not approval.get("approved"):
        return {"status": "rejected", "reason": approval.get("feedback")}

    context.step(publish(summary, approval), name="publish")
    return {"status": "published"}
