import json
import os

import boto3


s3 = boto3.client("s3")
cloudwatch = boto3.client("cloudwatch")


RAW_BUCKET = os.environ["RAW_BUCKET"]
CURATED_BUCKET = os.environ["CURATED_BUCKET"]
YOLO_PREFIX = os.environ.get("YOLO_PREFIX", "yolo_dataset/").strip("/")
DATASET_S3_URI = f"s3://{CURATED_BUCKET}/{YOLO_PREFIX}/"


def log(level, event, **fields):
    print(json.dumps({"level": level, "event": event, **fields}, default=str))


def count_objects(bucket, prefix):
    paginator = s3.get_paginator("list_objects_v2")
    count = 0
    for page in paginator.paginate(Bucket=bucket, Prefix=prefix):
        count += len(page.get("Contents", []))
    return count


def ensure_object(bucket, key):
    try:
        s3.head_object(Bucket=bucket, Key=key)
    except Exception as exc:
        raise FileNotFoundError(f"Missing required S3 object: s3://{bucket}/{key}") from exc


def put_storage_metrics(total_objects, train_images, val_images):
    cloudwatch.put_metric_data(
        Namespace="KittiMLProject/Storage",
        MetricData=[
            {"MetricName": "CuratedObjectCount", "Value": total_objects, "Unit": "Count"},
            {"MetricName": "YoloTrainImages", "Value": train_images, "Unit": "Count"},
            {"MetricName": "YoloValImages", "Value": val_images, "Unit": "Count"},
        ],
    )


def lambda_handler(event, context):
    event = event or {}
    mode = event.get("mode", "sample")
    sample_size = int(event.get("sample_size", 100))
    deploy_endpoint = bool(event.get("deploy_endpoint", False))

    yaml_key = f"{YOLO_PREFIX}/kitti.yaml"
    train_prefix = f"{YOLO_PREFIX}/images/train/"
    val_prefix = f"{YOLO_PREFIX}/images/val/"
    label_train_prefix = f"{YOLO_PREFIX}/labels/train/"
    label_val_prefix = f"{YOLO_PREFIX}/labels/val/"

    ensure_object(CURATED_BUCKET, yaml_key)

    train_images = count_objects(CURATED_BUCKET, train_prefix)
    val_images = count_objects(CURATED_BUCKET, val_prefix)
    train_labels = count_objects(CURATED_BUCKET, label_train_prefix)
    val_labels = count_objects(CURATED_BUCKET, label_val_prefix)
    total_objects = train_images + val_images + train_labels + val_labels + 1

    if train_images == 0 or val_images == 0:
        raise ValueError(f"YOLO dataset is incomplete at {DATASET_S3_URI}")

    put_storage_metrics(total_objects, train_images, val_images)

    result = {
        "mode": mode,
        "sample_size": sample_size,
        "deploy_endpoint": deploy_endpoint,
        "raw_bucket": RAW_BUCKET,
        "curated_bucket": CURATED_BUCKET,
        "dataset_s3_uri": DATASET_S3_URI,
        "dataset_yaml": f"{DATASET_S3_URI}kitti.yaml",
        "train_images": train_images,
        "val_images": val_images,
        "train_labels": train_labels,
        "val_labels": val_labels,
    }

    log("INFO", "prepare_yolo_dataset_verified", **result)
    return result
