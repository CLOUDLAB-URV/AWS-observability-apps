"""Lambda de upload: recibe un CSV por API Gateway y lo sube a S3.

Formato del body aceptado: texto CSV crudo (text/csv o text/plain).
API Gateway puede entregarlo base64-encoded si la payload es binaria.
"""
import base64
import json
import os
import time

import boto3

BUCKET_NAME = os.environ["BUCKET_NAME"]
s3 = boto3.client("s3")


def lambda_handler(event, context):
    try:
        raw = event.get("body", "")
        if event.get("isBase64Encoded"):
            raw = base64.b64decode(raw).decode("utf-8")
        elif raw is None:
            raw = ""

        if not raw.strip():
            return _response(400, {"error": "Body vacio. Envie un CSV en el body."})

        key = f"uploads/{int(time.time() * 1000)}.csv"
        s3.put_object(Bucket=BUCKET_NAME, Key=key, Body=raw.encode("utf-8"))

        return _response(
            202,
            {
                "message": "Fichero subido. Se procesara de forma asincrona.",
                "bucket": BUCKET_NAME,
                "key": key,
                "bytes": len(raw),
            },
        )
    except Exception as exc:
        return _response(500, {"error": str(exc)})


def _response(status, body):
    return {
        "statusCode": status,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(body),
    }