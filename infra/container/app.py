#!/usr/bin/env python3
"""OpenAI-compatible /v1 proxy over Amazon Bedrock (Converse).

Stateless. Reads BEDROCK_MODEL_ID, LINEAGE_BUCKET, AWS_REGION from env.
Shadows per-request lineage to the S3 lineage bucket (best-effort) + logs to stdout.
Pure translation logic is stdlib-only so it self-checks without fastapi/boto3 installed.
"""
import os, json, time, uuid, datetime

# --- pure logic (stdlib only, testable) -------------------------------------

def translate_messages(messages):
    """OpenAI messages -> (system text list, converse messages list, inferenceConfig)."""
    system = [m["content"] for m in messages if m.get("role") == "system"]
    convo = [{"role": m["role"], "content": [{"text": m["content"]}]}
             for m in messages if m.get("role") != "system"]
    cfg: dict = {"maxTokens": int(os.environ.get("MAX_TOKENS", "512"))}
    if os.environ.get("TEMPERATURE"):
        cfg["temperature"] = float(os.environ["TEMPERATURE"])
    return system, convo, cfg


def to_openai(resp, model):
    """Bedrock Converse response dict -> OpenAI chat.completion dict."""
    text = "".join(c.get("text", "") for c in resp.get("output", {}).get("message", {}).get("content", []))
    u = resp.get("usage", {}) or {}
    pin, cout = u.get("inputTokens", 0), u.get("outputTokens", 0)
    return {
        "object": "chat.completion", "model": model,
        "choices": [{"index": 0, "message": {"role": "assistant", "content": text}, "finish_reason": "stop"}],
        "usage": {"prompt_tokens": pin, "completion_tokens": cout, "total_tokens": pin + cout},
    }


def lineage_payload(model, request_id, latency_ms, success, usage):
    return {
        "model": model, "request_id": request_id,
        "prompt_tokens": usage.get("prompt_tokens", 0),
        "completion_tokens": usage.get("completion_tokens", 0),
        "latency_ms": latency_ms, "timestamp": datetime.datetime.utcnow().isoformat(),
        "success": success,
    }


# --- wiring (fastapi + boto3; guard so self-check works without them) -------

try:
    from fastapi import FastAPI, Request
    from fastapi.responses import JSONResponse
    import boto3
    app = FastAPI()
    _region = os.environ.get("AWS_REGION", "us-east-1")

    def _clients():
        return (boto3.client("bedrock-runtime", region_name=_region),
                boto3.client("s3", region_name=_region))

    @app.get("/v1/models")
    def models():
        return {"object": "list", "data": [{"id": os.environ["BEDROCK_MODEL_ID"], "object": "model"}]}

    @app.post("/v1/chat/completions")
    async def chat(req: Request):
        body = await req.json()
        model = os.environ["BEDROCK_MODEL_ID"]
        rid = str(uuid.uuid4())
        start = time.time()
        try:
            system, convo, cfg = translate_messages(body.get("messages", []))
            kw = {"modelId": model, "messages": convo, "inferenceConfig": cfg}
            if system:
                kw["system"] = [{"text": s} for s in system]
            br, _ = _clients()
            out = to_openai(br.converse(**kw), model)
            ok = True
        except Exception as e:  # noqa: BLE001 - surface to client, still record lineage
            out = {"error": str(e)}
            ok = False
        # lineage shadow (best-effort — never fail the request on a storage hiccup)
        try:
            _, s3 = _clients()
            payload = lineage_payload(model, rid, round((time.time() - start) * 1000, 2), ok, out.get("usage", {}))
            key = datetime.date.today().isoformat() + "/" + rid + ".json"
            s3.put_object(Bucket=os.environ["LINEAGE_BUCKET"], Key=key, Body=json.dumps(payload))
        except Exception as e:  # noqa: BLE001
            print(json.dumps({"log": "lineage_write_failed", "request_id": rid, "error": str(e)}))
        return JSONResponse(out, status_code=200 if ok else 502)

except ImportError:  # fastapi/boto3 not installed (e.g. local stdlib-only self-check)
    app = None


if __name__ == "__main__":
    # self-check: pure translation + lineage logic (no fastapi/boto3 needed)
    sys = translate_messages([{"role": "system", "content": "be terse"},
                              {"role": "user", "content": "hi"}])
    assert sys[0] == ["be terse"], sys[0]
    assert sys[1] == [{"role": "user", "content": [{"text": "hi"}]}], sys[1]
    assert sys[2]["maxTokens"] == 512, sys[2]
    resp = {"output": {"message": {"content": [{"text": "hello "}, {"text": "world"}]}},
            "usage": {"inputTokens": 7, "outputTokens": 2}}
    oai = to_openai(resp, "nvidia.nemotron-super-3-120b")
    assert oai["choices"][0]["message"]["content"] == "hello world", oai["choices"]
    assert oai["usage"] == {"prompt_tokens": 7, "completion_tokens": 2, "total_tokens": 9}, oai["usage"]
    lp = lineage_payload("nvidia.nemotron-super-3-120b", "r1", 12.3, True, oai["usage"])
    assert lp["latency_ms"] == 12.3 and lp["success"] is True and lp["model"].endswith("120b"), lp
    print("SELF-CHECK PASS")
