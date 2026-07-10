"""Lambda de procesamiento: disparada por S3 event.

Descarga el fichero CSV de S3, lo parsea y agrega por (metric, date)
guardando count y sum en DynamoDB. La media se calcula on-read.
Formato CSV esperado (cabecera incluida o no):
    timestamp,metric,value
    2026-07-09T10:00:00Z,cpu,12.5
    2026-07-09T10:01:00Z,cpu,15.0
    2026-07-09T10:00:00Z,mem,4096
"""
import csv
import io
import os
from decimal import Decimal

import boto3

TABLE_NAME = os.environ["TABLE_NAME"]
s3 = boto3.client("s3")
dynamodb = boto3.resource("dynamodb")
table = dynamodb.Table(TABLE_NAME)


def lambda_handler(event, context):
    total_rows = 0
    processed_files = 0

    for record in event.get("Records", []):
        bucket = record["s3"]["bucket"]["name"]
        key = record["s3"]["object"]["key"]
        aggregated, rows = _aggregate_csv(bucket, key)
        _persist(aggregated)
        total_rows += rows
        processed_files += 1

    return {
        "processed_files": processed_files,
        "total_rows": total_rows,
    }


def _aggregate_csv(bucket, key):
    obj = s3.get_object(Bucket=bucket, Key=key)
    body = obj["Body"].read().decode("utf-8")

    reader = csv.DictReader(io.StringIO(body))
    if reader.fieldnames is None:
        return {}, 0

    # Normaliza cabeceras: acepta timestamp/metric/value en cualquier orden/case.
    fieldnames = {f.lower().strip(): f for f in reader.fieldnames}
    ts_field = fieldnames.get("timestamp")
    metric_field = fieldnames.get("metric")
    value_field = fieldnames.get("value")
    if not (ts_field and metric_field and value_field):
        return {}, 0

    agg = {}
    rows = 0
    for row in reader:
        try:
            ts = row[ts_field] or ""
            metric = (row[metric_field] or "").strip()
            value = Decimal(row[value_field])
        except (TypeError, ValueError, ArithmeticError):
            continue
        if not metric:
            continue
        date = ts[:10] or "unknown"
        key_agg = (metric, date)
        bucket_stats = agg.setdefault(key_agg, {"count": Decimal(0), "sum": Decimal(0)})
        bucket_stats["count"] += Decimal(1)
        bucket_stats["sum"] += value
        rows += 1
    return agg, rows


def _persist(agg):
    for (metric, date), stats in agg.items():
        pk = f"{date}"
        table.update_item(
            Key={"metric_date": pk, "metric": metric},
            UpdateExpression="ADD #c :c, #s :s "
            "SET last_updated = :now",
            ExpressionAttributeNames={"#c": "count", "#s": "sum"},
            ExpressionAttributeValues={
                ":c": stats["count"],
                ":s": stats["sum"],
                ":now": _now_iso(),
            },
        )


def _now_iso():
    import datetime

    return datetime.datetime.utcnow().isoformat() + "Z"