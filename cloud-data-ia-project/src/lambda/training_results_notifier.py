import json
import os
import tarfile
import tempfile
from urllib.parse import urlparse

import boto3


s3 = boto3.client("s3")
sns = boto3.client("sns")
sagemaker = boto3.client("sagemaker")


MODEL_ARTIFACTS_BUCKET = os.environ["MODEL_ARTIFACTS_BUCKET"]
RESULTS_PREFIX = os.environ.get("RESULTS_PREFIX", "training-results/").strip("/")
SNS_TOPIC_ARN = os.environ.get("SNS_TOPIC_ARN", "")
PRESIGNED_URL_EXPIRES_SECONDS = int(os.environ.get("PRESIGNED_URL_EXPIRES_SECONDS", "604800"))
TRAINING_OUTPUT_PREFIX = os.environ.get("TRAINING_OUTPUT_PREFIX", "training-output/").strip("/")


def log(level, event, **fields):
    print(json.dumps({"level": level, "event": event, **fields}, default=str))


def parse_s3_uri(uri):
    parsed = urlparse(uri)
    if parsed.scheme != "s3" or not parsed.netloc or not parsed.path:
        raise ValueError(f"Invalid S3 URI: {uri}")
    return parsed.netloc, parsed.path.lstrip("/")


def get_training_job_name(event):
    candidates = [
        event.get("training_job_name"),
        event.get("TrainingJobName"),
        event.get("training_job", {}).get("TrainingJobName"),
        event.get("detail", {}).get("TrainingJobName"),
    ]

    for candidate in candidates:
        if candidate:
            return candidate

    raise ValueError("training_job_name is required")


def get_model_artifact_uri(event, training_job_name):
    explicit_uri = event.get("model_artifact_s3_uri") or event.get("ModelArtifactS3Uri")
    if explicit_uri:
        return explicit_uri

    try:
        description = sagemaker.describe_training_job(TrainingJobName=training_job_name)
        artifact_uri = description.get("ModelArtifacts", {}).get("S3ModelArtifacts")
        if artifact_uri:
            return artifact_uri
    except Exception as exc:
        log("WARN", "describe_training_job_failed", training_job_name=training_job_name, error=str(exc))

    return f"s3://{MODEL_ARTIFACTS_BUCKET}/{TRAINING_OUTPUT_PREFIX}/{training_job_name}/output/model.tar.gz"


def find_tar_member(tar, filename):
    preferred = f"evaluation/{filename}"
    fallback = None

    for member in tar.getmembers():
        normalized = member.name.lstrip("./")
        if not member.isfile():
            continue
        if normalized == preferred:
            return member
        if normalized.endswith(f"/{filename}") or normalized == filename:
            fallback = member

    return fallback


def read_required_artifact(tar, filename):
    member = find_tar_member(tar, filename)
    if member is None:
        raise FileNotFoundError(f"{filename} was not found inside model.tar.gz")

    extracted = tar.extractfile(member)
    if extracted is None:
        raise FileNotFoundError(f"{filename} could not be read inside model.tar.gz")

    return extracted.read()


def upload_artifact(bucket, key, body, content_type):
    s3.put_object(
        Bucket=bucket,
        Key=key,
        Body=body,
        ContentType=content_type,
    )
    return f"s3://{bucket}/{key}"


def presign(bucket, key):
    return s3.generate_presigned_url(
        "get_object",
        Params={"Bucket": bucket, "Key": key},
        ExpiresIn=PRESIGNED_URL_EXPIRES_SECONDS,
    )


def publish_sns(response):
    if not SNS_TOPIC_ARN:
        return

    expires_hours = PRESIGNED_URL_EXPIRES_SECONDS // 3600
    message = "\n".join(
        [
            "KITTI YOLOv8 training results are ready.",
            "",
            f"Training job: {response['training_job_name']}",
            f"Model artifact: {response['model_artifact_s3_uri']}",
            "",
            "SNS email cannot attach files directly, so these are signed S3 links:",
            f"results.png: {response['results_png_url']}",
            f"results.csv: {response['results_csv_url']}",
            "",
            f"Links expire in about {expires_hours} hours.",
        ]
    )

    sns.publish(
        TopicArn=SNS_TOPIC_ARN,
        Subject="KITTI training results ready",
        Message=message,
    )


def lambda_handler(event, context):
    training_job_name = get_training_job_name(event)
    model_artifact_s3_uri = get_model_artifact_uri(event, training_job_name)
    artifact_bucket, artifact_key = parse_s3_uri(model_artifact_s3_uri)

    log(
        "INFO",
        "training_results_processing_started",
        training_job_name=training_job_name,
        model_artifact_s3_uri=model_artifact_s3_uri,
    )

    with tempfile.TemporaryDirectory() as tmpdir:
        model_tar_path = os.path.join(tmpdir, "model.tar.gz")
        s3.download_file(artifact_bucket, artifact_key, model_tar_path)

        with tarfile.open(model_tar_path, "r:gz") as tar:
            results_png = read_required_artifact(tar, "results.png")
            results_csv = read_required_artifact(tar, "results.csv")

    result_base_key = f"{RESULTS_PREFIX}/{training_job_name}"
    results_png_key = f"{result_base_key}/results.png"
    results_csv_key = f"{result_base_key}/results.csv"

    results_png_s3_uri = upload_artifact(
        MODEL_ARTIFACTS_BUCKET,
        results_png_key,
        results_png,
        "image/png",
    )
    results_csv_s3_uri = upload_artifact(
        MODEL_ARTIFACTS_BUCKET,
        results_csv_key,
        results_csv,
        "text/csv",
    )

    response = {
        "training_job_name": training_job_name,
        "model_artifact_s3_uri": model_artifact_s3_uri,
        "results_png_s3_uri": results_png_s3_uri,
        "results_csv_s3_uri": results_csv_s3_uri,
        "results_png_url": presign(MODEL_ARTIFACTS_BUCKET, results_png_key),
        "results_csv_url": presign(MODEL_ARTIFACTS_BUCKET, results_csv_key),
        "presigned_url_expires_seconds": PRESIGNED_URL_EXPIRES_SECONDS,
    }

    publish_sns(response)

    log(
        "INFO",
        "training_results_processing_completed",
        training_job_name=training_job_name,
        results_png_s3_uri=results_png_s3_uri,
        results_csv_s3_uri=results_csv_s3_uri,
    )

    return response
