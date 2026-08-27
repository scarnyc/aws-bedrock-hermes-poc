#!/usr/bin/env python3
"""OpenAI-compatible /v1 proxy over Amazon Bedrock (Converse).

Stateless. Reads BEDROCK_MODEL_ID, LINEAGE_BUCKET, AWS_REGION from env.
Shadows per-request lineage to the S3 lineage bucket (best-effort) + logs to stdout.
Pure translation logic is stdlib-only so it self-checks without fastapi/boto3 installed.
"""
import os, json, time, uuid, datetime

# --- pure logic (stdlib only, testable) -------------------------------------

_STOP_REASON = {"stop": "stop", "max_tokens": "length", "tool_use": "tool_calls",
                "content_filter": "content_filter", "stop_sequence": "stop"}


def translate_messages(messages, max_tokens=None, temperature=None):
    """OpenAI messages -> (system text list, converse messages list, inferenceConfig).

    max_tokens/temperature come from the request body when present, else env.
    """
    system = [m["content"] for m in messages if m.get("role") == "system"]
    convo = [{"role": m["role"], "content": [{"text": m["content"]}]}
             for m in messages if m.get("role") != "system"]
    cfg: dict = {"maxTokens": int(max_tokens or os.environ.get("MAX_TOKENS", "512"))}
    temp = temperature if temperature is not None else os.environ.get("TEMPERATURE")
    if temp:
        cfg["temperature"] = float(temp)
    return system, convo, cfg


def to_openai(resp, model):
    """Bedrock Converse response dict -> OpenAI chat.completion dict."""
    text = "".join(c.get("text", "") for c in resp.get("output", {}).get("message", {}).get("content", []))
    u = resp.get("usage", {}) or {}
    pin, cout = u.get("inputTokens", 0), u.get("outputTokens", 0)
    return {
        "object": "chat.completion", "model": model,
        "choices": [{"index": 0, "message": {"role": "assistant", "content": text},
                     "finish_reason": _STOP_REASON.get(resp.get("stopReason"), "stop")}],
        "usage": {"prompt_tokens": pin, "completion_tokens": cout, "total_tokens": pin + cout},
    }


def lineage_payload(model, request_id, latency_ms, success, usage):
    return {
        "model": model, "request_id": request_id,
        "prompt_tokens": usage.get("prompt_tokens", 0),
        "completion_tokens": usage.get("completion_tokens", 0),
        "latency_ms": latency_ms,
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "success": success,
    }


# --- wiring (fastapi + boto3; guard so self-check works without them) -------

try:
    from fastapi import FastAPI, Request
    from fastapi.responses import JSONResponse
    import boto3
    _region = os.environ.get("AWS_REGION", "us-east-1")
    _BR = boto3.client("bedrock-runtime", region_name=_region)   # hoisted: reuse per-request
    _S3 = boto3.client("s3", region_name=_region)
    _model = os.environ.get("BEDROCK_MODEL_ID", "unset")          # no 500 on bare run

    app = FastAPI()

    @app.get("/v1/models")
    def models():
        return {"object": "list", "data": [{"id": _model, "object": "model"}]}

    @app.post("/v1/chat/completions")
    async def chat(req: Request):
        body = await req.json()
        model = os.environ.get("BEDROCK_MODEL_ID")
        rid = str(uuid.uuid4())
        start = time.time()
        try:
            system, convo, cfg = translate_messages(
                body.get("messages", []), body.get("max_tokens"), body.get("temperature"))
            kw = {"modelId": model, "messages": convo, "inferenceConfig": cfg}
            if system:
                kw["system"] = [{"text": s} for s in system]
                # Bedrock prompt caching is Anthropic-only (Nemotron/others reject
                # cachePoint). Cache the system prefix so repeated calls (e.g. a
                # Hermes agent loop, same streamed system prompt) hit cacheRead
                # pricing instead of full input. ponytail: only emit for large
                # system prompts (>= ~2000 tokens char-approx); smaller ones would
                # sit under the model's minimum cacheable length.
                if model and "anthropic" in model and sum(len(s) for s in system) >= 8000:
                    kw["system"].append({"cachePoint": {"type": "default"}})
            out = to_openai(_BR.converse(**kw), model)
            ok = True
        except Exception as e:  # noqa: BLE001 - surface generic error, record lineage
            out = {"error": {"message": "model invocation failed"}}
            print(json.dumps({"log": "invoke_failed", "request_id": rid, "error": str(e)}))
            ok = False
        # lineage shadow (best-effort — never fail the request on a storage hiccup)
        try:
            payload = lineage_payload(model, rid, round((time.time() - start) * 1000, 2), ok, out.get("usage", {}))
            key = datetime.date.today().isoformat() + "/" + rid + ".json"
            _S3.put_object(Bucket=os.environ["LINEAGE_BUCKET"], Key=key, Body=json.dumps(payload))
        except Exception as e:  # noqa: BLE001
            print(json.dumps({"log": "lineage_write_failed", "request_id": rid, "error": str(e)}))
        return JSONResponse(out, status_code=200 if ok else 502)

except ImportError:  # fastapi/boto3 not installed (e.g. local stdlib-only self-check)
    app = None


if __name__ == "__main__":
    # self-check: pure translation + lineage logic (no fastapi/boto3 needed)
    sys0, convo, cfg = translate_messages([{"role": "system", "content": "be terse"},
                                           {"role": "user", "content": "hi"}])
    assert sys0 == ["be terse"], sys0
    assert convo == [{"role": "user", "content": [{"text": "hi"}]}], convo
    assert cfg["maxTokens"] == 512, cfg
    # request-body override wins over env
    cfg2 = translate_messages([{"role": "user", "content": "x"}], max_tokens=64, temperature=0.2)[2]
    assert cfg2 == {"maxTokens": 64, "temperature": 0.2}, cfg2
    resp = {"output": {"message": {"content": [{"text": "hello "}, {"text": "world"}]}},
            "usage": {"inputTokens": 7, "outputTokens": 2}, "stopReason": "max_tokens"}
    oai = to_openai(resp, "nvidia.nemotron-super-3-120b")
    assert oai["choices"][0]["message"]["content"] == "hello world", oai["choices"]
    assert oai["choices"][0]["finish_reason"] == "length", oai["choices"]
    assert oai["usage"] == {"prompt_tokens": 7, "completion_tokens": 2, "total_tokens": 9}, oai["usage"]
    lp = lineage_payload("nvidia.nemotron-super-3-120b", "r1", 12.3, True, oai["usage"])
    assert lp["latency_ms"] == 12.3 and lp["success"] is True and lp["model"].endswith("120b"), lp
    print("SELF-CHECK PASS")
