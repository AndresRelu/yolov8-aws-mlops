import io
import json
import os

import numpy as np
from PIL import Image
from ultralytics import YOLO


DEFAULT_CONFIDENCE = float(os.environ.get("DEFAULT_CONFIDENCE_THRESHOLD", "0.25"))


def model_fn(model_dir):
    model_path = os.path.join(model_dir, "best.pt")
    if not os.path.exists(model_path):
        raise FileNotFoundError(f"Model artifact not found at {model_path}")
    return YOLO(model_path)


def input_fn(request_body, content_type):
    if content_type in ("application/json", "application/json; charset=utf-8"):
        payload = json.loads(request_body.decode("utf-8") if isinstance(request_body, bytes) else request_body)
        if "image_base64" not in payload:
            raise ValueError("JSON payload must include image_base64")

        import base64

        request_body = base64.b64decode(payload["image_base64"])
        content_type = payload.get("content_type", "image/png")

    if content_type.startswith("image/") or content_type == "application/octet-stream":
        image = Image.open(io.BytesIO(request_body))
        return image.convert("RGB")

    raise ValueError(f"Unsupported content type: {content_type}")


def predict_fn(input_data, model):
    results = model.predict(input_data, conf=DEFAULT_CONFIDENCE, verbose=False)
    detections = []

    for result in results:
        names = result.names or {}
        boxes = result.boxes
        if boxes is None:
            continue

        xyxy = boxes.xyxy.cpu().numpy()
        confidences = boxes.conf.cpu().numpy()
        class_ids = boxes.cls.cpu().numpy().astype(int)

        for box, confidence, class_id in zip(xyxy, confidences, class_ids):
            detections.append(
                {
                    "class_id": int(class_id),
                    "class_name": str(names.get(int(class_id), class_id)),
                    "confidence": float(confidence),
                    "bbox": [float(value) for value in np.round(box, 2).tolist()],
                }
            )

    return {"detections": detections}


def output_fn(prediction, accept):
    if accept not in ("application/json", "*/*"):
        raise ValueError(f"Unsupported accept type: {accept}")

    return json.dumps(prediction), "application/json"
