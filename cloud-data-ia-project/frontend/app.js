const DEFAULT_API_BASE_URL = "https://15sd6fc639.execute-api.us-east-1.amazonaws.com/dev";

const els = {
  apiBaseUrl: document.querySelector("#apiBaseUrl"),
  apiKey: document.querySelector("#apiKey"),
  confidence: document.querySelector("#confidence"),
  confidenceValue: document.querySelector("#confidenceValue"),
  startCamera: document.querySelector("#startCamera"),
  checkHealth: document.querySelector("#checkHealth"),
  predict: document.querySelector("#predict"),
  video: document.querySelector("#video"),
  overlay: document.querySelector("#overlay"),
  capture: document.querySelector("#capture"),
  status: document.querySelector("#status"),
  endpointStatus: document.querySelector("#endpointStatus"),
  detectionCount: document.querySelector("#detectionCount"),
  detections: document.querySelector("#detections"),
  rawResponse: document.querySelector("#rawResponse"),
};

let stream = null;

els.apiBaseUrl.value = localStorage.getItem("kittiApiBaseUrl") || DEFAULT_API_BASE_URL;

function setStatus(message, type = "") {
  els.status.textContent = message;
  els.status.className = `status ${type}`.trim();
}

function endpointUrl(path) {
  const baseUrl = els.apiBaseUrl.value.trim().replace(/\/$/, "");
  if (!baseUrl) {
    throw new Error("API URL requerida");
  }
  localStorage.setItem("kittiApiBaseUrl", baseUrl);
  return `${baseUrl}${path}`;
}

function updatePredictState() {
  els.predict.disabled = !stream || !els.apiKey.value.trim();
}

function syncOverlaySize() {
  const width = els.video.videoWidth || 1280;
  const height = els.video.videoHeight || 720;
  els.overlay.width = width;
  els.overlay.height = height;
  els.capture.width = width;
  els.capture.height = height;
}

function clearOverlay() {
  const ctx = els.overlay.getContext("2d");
  ctx.clearRect(0, 0, els.overlay.width, els.overlay.height);
}

async function parseJsonResponse(response) {
  const text = await response.text();
  let data = {};

  try {
    data = text ? JSON.parse(text) : {};
  } catch {
    data = { raw: text };
  }

  if (!response.ok) {
    throw new Error(data.detail || data.error || response.statusText);
  }

  return data;
}

async function checkHealth() {
  setStatus("Checking");
  try {
    const response = await fetch(endpointUrl("/health"));
    const data = await parseJsonResponse(response);
    els.endpointStatus.textContent = data.endpoint_status || "Unknown";
    els.rawResponse.textContent = JSON.stringify(data, null, 2);
    setStatus("Health OK", "ok");
  } catch (error) {
    els.endpointStatus.textContent = "Error";
    setStatus(error.message, "error");
  }
}

async function startCamera() {
  setStatus("Opening camera");

  try {
    stream = await navigator.mediaDevices.getUserMedia({
      video: {
        width: { ideal: 1280 },
        height: { ideal: 720 },
      },
      audio: false,
    });

    els.video.srcObject = stream;
    await els.video.play();
    syncOverlaySize();
    clearOverlay();
    setStatus("Camera ready", "ok");
    updatePredictState();
  } catch (error) {
    setStatus(error.message, "error");
  }
}

function canvasToBlob(canvas) {
  return new Promise((resolve, reject) => {
    canvas.toBlob(
      (blob) => {
        if (blob) {
          resolve(blob);
        } else {
          reject(new Error("No se pudo capturar imagen"));
        }
      },
      "image/jpeg",
      0.88,
    );
  });
}

function blobToBase64(blob) {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => resolve(String(reader.result).split(",")[1]);
    reader.onerror = () => reject(reader.error || new Error("No se pudo leer imagen"));
    reader.readAsDataURL(blob);
  });
}

async function captureBase64Frame() {
  syncOverlaySize();
  const ctx = els.capture.getContext("2d");
  ctx.drawImage(els.video, 0, 0, els.capture.width, els.capture.height);
  return blobToBase64(await canvasToBlob(els.capture));
}

function getDetectionBox(detection) {
  if (Array.isArray(detection.bbox) && detection.bbox.length >= 4) {
    return detection.bbox.map(Number);
  }

  const box = detection.bbox || detection.box || detection.bounding_box;
  if (box && typeof box === "object") {
    return [
      Number(box.xmin ?? box.x_min ?? box.left ?? box.x1),
      Number(box.ymin ?? box.y_min ?? box.top ?? box.y1),
      Number(box.xmax ?? box.x_max ?? box.right ?? box.x2),
      Number(box.ymax ?? box.y_max ?? box.bottom ?? box.y2),
    ];
  }

  return null;
}

function normalizeBox(box) {
  const maxValue = Math.max(...box.map((value) => Math.abs(value)));
  if (maxValue <= 1) {
    return [
      box[0] * els.overlay.width,
      box[1] * els.overlay.height,
      box[2] * els.overlay.width,
      box[3] * els.overlay.height,
    ];
  }
  return box;
}

function drawDetections(detections) {
  syncOverlaySize();
  clearOverlay();

  const ctx = els.overlay.getContext("2d");
  const colors = ["#22c55e", "#f59e0b", "#38bdf8", "#ef4444", "#a3e635"];
  ctx.lineWidth = Math.max(2, Math.round(els.overlay.width / 420));
  ctx.font = `${Math.max(13, Math.round(els.overlay.width / 70))}px system-ui`;

  detections.forEach((detection, index) => {
    const rawBox = getDetectionBox(detection);
    if (!rawBox || rawBox.some((value) => Number.isNaN(value))) {
      return;
    }

    const [x1, y1, x2, y2] = normalizeBox(rawBox);
    const color = colors[index % colors.length];
    const label = `${detection.class_name ?? detection.class ?? "Object"} ${Math.round(
      Number(detection.confidence ?? detection.score ?? 0) * 100,
    )}%`;
    const width = Math.max(1, x2 - x1);
    const height = Math.max(1, y2 - y1);
    const labelWidth = ctx.measureText(label).width + 12;
    const labelHeight = 24;
    const labelY = Math.max(0, y1 - labelHeight);

    ctx.strokeStyle = color;
    ctx.fillStyle = color;
    ctx.strokeRect(x1, y1, width, height);
    ctx.fillRect(x1, labelY, labelWidth, labelHeight);
    ctx.fillStyle = "#071015";
    ctx.fillText(label, x1 + 6, labelY + 17);
  });
}

function renderDetections(detections) {
  els.detections.replaceChildren();
  els.detectionCount.textContent = String(detections.length);

  if (!detections.length) {
    const item = document.createElement("li");
    item.innerHTML = "<span>Sin detecciones</span><strong>0%</strong>";
    els.detections.append(item);
    return;
  }

  detections.forEach((detection) => {
    const item = document.createElement("li");
    const name = document.createElement("span");
    const confidence = document.createElement("strong");
    name.textContent = detection.class_name ?? detection.class ?? "Object";
    confidence.textContent = `${Math.round(Number(detection.confidence ?? detection.score ?? 0) * 100)}%`;
    item.append(name, confidence);
    els.detections.append(item);
  });
}

async function predictFrame() {
  if (!stream) {
    setStatus("Camara no disponible", "error");
    return;
  }

  const apiKey = els.apiKey.value.trim();
  if (!apiKey) {
    setStatus("API key requerida", "error");
    return;
  }

  setStatus("Predicting");

  try {
    const imageBase64 = await captureBase64Frame();
    const response = await fetch(endpointUrl("/predict"), {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "x-api-key": apiKey,
      },
      body: JSON.stringify({
        image_base64: imageBase64,
        content_type: "image/jpeg",
        confidence_threshold: Number(els.confidence.value),
      }),
    });
    const data = await parseJsonResponse(response);
    const detections = Array.isArray(data.detections) ? data.detections : [];

    els.endpointStatus.textContent = data.endpoint_name || "Ready";
    els.rawResponse.textContent = JSON.stringify(data, null, 2);
    renderDetections(detections);
    drawDetections(detections);
    setStatus("Prediction OK", "ok");
  } catch (error) {
    setStatus(error.message, "error");
  }
}

els.startCamera.addEventListener("click", startCamera);
els.checkHealth.addEventListener("click", checkHealth);
els.predict.addEventListener("click", predictFrame);
els.apiKey.addEventListener("input", updatePredictState);
els.video.addEventListener("loadedmetadata", syncOverlaySize);
els.confidence.addEventListener("input", () => {
  els.confidenceValue.value = Number(els.confidence.value).toFixed(2);
});

updatePredictState();
