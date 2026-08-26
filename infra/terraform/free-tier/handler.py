import json, os

def lambda_handler(event, context):
    """Free-tier health/proxy stub. Returns which Bedrock model the stack targets."""
    return {
        "statusCode": 200,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps({
            "service": "ml-platform",
            "bedrock_model_id": os.environ.get("BEDROCK_MODEL_ID", "unset"),
            "lineage_bucket": os.environ.get("LINEAGE_BUCKET", "unset"),
            "healthy": True,
        }),
    }
