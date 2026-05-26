import base64
import binascii
import json
import os
from collections import Counter

import boto3


s3 = boto3.client("s3")
sagemaker = boto3.client("sagemaker")
sagemaker_runtime = boto3.client("sagemaker-runtime")


ENDPOINT_NAME = os.environ["SAGEMAKER_ENDPOINT_NAME"]
ALLOWED_BUCKETS = {
    bucket.strip()
    for bucket in os.environ.get("ALLOWED_IMAGE_BUCKETS", "").split(",")
    if bucket.strip()
}
DEFAULT_CONFIDENCE = float(os.environ.get("DEFAULT_CONFIDENCE_THRESHOLD", "0.7"))
MAX_IMAGE_BYTES = int(os.environ.get("MAX_IMAGE_BYTES", "6000000"))
CORS_ORIGIN = os.environ.get("CORS_ORIGIN", "*")


def log(level, event, **fields):
    print(json.dumps({"level": level, "event": event, **fields}, default=str))


def response(status_code, body):
    return {
        "statusCode": status_code,
        "headers": {
            "Content-Type": "application/json",
            "Access-Control-Allow-Origin": CORS_ORIGIN,
            "Access-Control-Allow-Headers": "Content-Type,x-api-key",
            "Access-Control-Allow-Methods": "GET,POST,OPTIONS",
        },
        "body": json.dumps(body, default=str),
    }


def get_header(event, name, default=None):
    headers = event.get("headers") or {}
    lower_headers = {str(key).lower(): value for key, value in headers.items()}
    return lower_headers.get(name.lower(), default)


def decode_base64(value):
    try:
        return base64.b64decode(value, validate=True)
    except (binascii.Error, ValueError) as exc:
        raise ValueError("Invalid base64 image data") from exc


def parse_confidence(value):
    try:
        confidence = float(value)
    except (TypeError, ValueError) as exc:
        raise ValueError("confidence_threshold must be a number") from exc

    if confidence < 0 or confidence > 1:
        raise ValueError("confidence_threshold must be between 0 and 1")
    return confidence


def load_image_from_s3(bucket, key):
    if ALLOWED_BUCKETS and bucket not in ALLOWED_BUCKETS:
        raise ValueError(f"Bucket not allowed: {bucket}")

    obj = s3.get_object(Bucket=bucket, Key=key)
    image_bytes = obj["Body"].read()
    content_type = obj.get("ContentType") or "image/png"
    return image_bytes, content_type


def load_image_from_event(event):
    content_type = get_header(event, "content-type", "application/json")
    body = event.get("body") or ""

    if event.get("isBase64Encoded") and content_type.startswith("image/"):
        return decode_base64(body), content_type, DEFAULT_CONFIDENCE, "binary-body"

    try:
        payload = json.loads(body) if isinstance(body, str) else body
    except json.JSONDecodeError as exc:
        raise ValueError("Body must be JSON or binary image data") from exc

    if not isinstance(payload, dict):
        raise ValueError("JSON body must be an object")

    confidence = parse_confidence(payload.get("confidence_threshold", DEFAULT_CONFIDENCE))

    if "s3_bucket" in payload and "s3_key" in payload:
        image_bytes, s3_content_type = load_image_from_s3(payload["s3_bucket"], payload["s3_key"])
        return image_bytes, payload.get("content_type", s3_content_type), confidence, "s3-reference"

    if "image_base64" in payload:
        return (
            decode_base64(payload["image_base64"]),
            payload.get("content_type", "image/png"),
            confidence,
            "json-base64",
        )

    raise ValueError("Request must include image_base64 or s3_bucket+s3_key")


def invoke_model(image_bytes, content_type):
    if len(image_bytes) > MAX_IMAGE_BYTES:
        raise ValueError(f"Image is too large: {len(image_bytes)} bytes. Max is {MAX_IMAGE_BYTES} bytes.")

    result = sagemaker_runtime.invoke_endpoint(
        EndpointName=ENDPOINT_NAME,
        ContentType=content_type,
        Accept="application/json",
        Body=image_bytes,
    )
    raw_body = result["Body"].read().decode("utf-8")
    return json.loads(raw_body)


def normalize_detections(model_response):
    if isinstance(model_response, list):
        return model_response

    if isinstance(model_response, dict):
        if isinstance(model_response.get("detections"), list):
            return model_response["detections"]
        if isinstance(model_response.get("predictions"), list):
            return model_response["predictions"]

    return []


def detection_confidence(detection):
    return float(detection.get("confidence", detection.get("score", 0.0)))


def detection_class_name(detection):
    return detection.get("class_name", str(detection.get("class", "Unknown")))


def summarize(detections, threshold):
    filtered = [
        detection
        for detection in detections
        if detection_confidence(detection) >= threshold
    ]
    counts = Counter(detection_class_name(detection) for detection in filtered)

    if not counts:
        return "Detectados: 0 objetos con confianza >{:.1f}".format(threshold), filtered

    parts = [f"{count} {name}" for name, count in sorted(counts.items())]
    return "Detectados: {} con confianza >{:.1f}".format(", ".join(parts), threshold), filtered


def health():
    endpoint_status = "Unknown"
    try:
        endpoint_status = sagemaker.describe_endpoint(EndpointName=ENDPOINT_NAME)["EndpointStatus"]
    except Exception as exc:
        log("WARN", "endpoint_health_check_failed", error=str(exc), endpoint_name=ENDPOINT_NAME)

    return response(
        200,
        {
            "status": "ok",
            "service": "kitti-rest-api",
            "endpoint_name": ENDPOINT_NAME,
            "endpoint_status": endpoint_status,
        },
    )


def lambda_handler(event, context):
    method = event.get("httpMethod", "")
    path = event.get("path", "")

    if method == "OPTIONS":
        return response(200, {"ok": True})

    if method == "GET" and path.endswith("/health"):
        return health()

    if method != "POST" or not path.endswith("/predict"):
        return response(404, {"error": "Not found"})

    try:
        image_bytes, content_type, confidence, source = load_image_from_event(event)
        model_response = invoke_model(image_bytes, content_type)
        detections = normalize_detections(model_response)
        summary, filtered = summarize(detections, confidence)

        log(
            "INFO",
            "api_prediction_completed",
            source=source,
            content_type=content_type,
            image_bytes=len(image_bytes),
            detections=len(filtered),
            endpoint_name=ENDPOINT_NAME,
        )

        return response(
            200,
            {
                "summary": summary,
                "count": len(filtered),
                "detections": filtered,
                "endpoint_name": ENDPOINT_NAME,
            },
        )
    except ValueError as exc:
        log("WARN", "bad_request", error=str(exc))
        return response(400, {"error": str(exc)})
    except Exception as exc:
        log("ERROR", "api_prediction_failed", error=str(exc), endpoint_name=ENDPOINT_NAME)
        return response(500, {"error": "Prediction failed", "detail": str(exc)})
