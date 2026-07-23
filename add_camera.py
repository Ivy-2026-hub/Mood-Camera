#!/usr/bin/env python3
"""Turn almost any camera design into a MoodPolaroid camera skin.

Usage:
    python add_camera.py toy_f.png --name polaroid --display 拍立得

Runtime dependencies are intentionally limited to Pillow and requests.
Set OPENAI_API_KEY to enable OpenAI vision. Without it, the script still
finishes through deterministic local fallbacks and marks controls as missing.
"""

from __future__ import annotations

import argparse
import base64
from collections import deque
from dataclasses import dataclass
import json
import math
import os
from pathlib import Path
import re
import sys
import tempfile
import time
from typing import Any, Iterable

try:
    from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont, ImageOps
except ImportError:
    Image = ImageChops = ImageDraw = ImageFilter = ImageFont = ImageOps = None

try:
    import requests
except ImportError:
    requests = None


TARGET_WIDTH = 1290
TARGET_HEIGHT = 2796
DETECTION_SCALE = 0.5
MAGENTA = (255, 0, 255)
ALLOWED_CONTROLS = (
    "shutter",
    "album",
    "flip",
    "flash",
    "timer",
    "zoom",
    "drawer",
)
DEFAULT_MODEL = "gpt-5.6"
DEFAULT_ENDPOINT = "https://api.openai.com/v1/responses"
NAME_PATTERN = re.compile(r"^[a-z][a-z0-9_]*$")


@dataclass(frozen=True)
class Component:
    count: int
    bbox: tuple[int, int, int, int]
    seed: tuple[int, int]

    @property
    def width(self) -> int:
        return self.bbox[2] - self.bbox[0] + 1

    @property
    def height(self) -> int:
        return self.bbox[3] - self.bbox[1] + 1

    @property
    def fill_ratio(self) -> float:
        return self.count / max(1, self.width * self.height)


@dataclass(frozen=True)
class DetectedViewport:
    x: float
    y: float
    width: float
    height: float
    corner_radius: float
    method: str

    def as_percent_dict(self, image_width: int, image_height: int) -> dict[str, float]:
        return {
            "x": round(self.x / image_width * 100, 5),
            "y": round(self.y / image_height * 100, 5),
            "width": round(self.width / image_width * 100, 5),
            "height": round(self.height / image_height * 100, 5),
            "corner_radius_width": round(
                self.corner_radius / image_width * 100, 5
            ),
        }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="把 GPT 相机设计图标准化、自动挖取景框、标注按键并写入 Xcode Assets。"
    )
    parser.add_argument("image", type=Path, nargs="?", help="GPT 生成的相机设计图 PNG")
    parser.add_argument("--name", help="稳定英文标识，例如 polaroid")
    parser.add_argument("--display", help="App 内显示名，例如 拍立得")
    parser.add_argument(
        "--rebuild-registry",
        action="store_true",
        help="只根据 definitions/*.json 重建 CameraSkins.swift",
    )
    parser.add_argument(
        "--fit",
        choices=("auto", "contain", "cover"),
        default="auto",
        help="标准化策略；auto 会在比例接近时裁剪，否则透明补边",
    )
    parser.add_argument(
        "--model",
        default=DEFAULT_MODEL,
        help=f"OpenAI 视觉模型名称，默认 {DEFAULT_MODEL}",
    )
    parser.add_argument(
        "--endpoint",
        default=DEFAULT_ENDPOINT,
        help="OpenAI Responses API 端点",
    )
    parser.add_argument(
        "--project-root",
        type=Path,
        default=Path(__file__).resolve().parent,
        help=argparse.SUPPRESS,
    )
    parser.add_argument(
        "--skip-vision",
        action="store_true",
        help="跳过 OpenAI，直接使用本地图像检测降级链路",
    )
    return parser.parse_args()


def validate_name(name: str) -> None:
    if not NAME_PATTERN.fullmatch(name):
        raise ValueError(
            "--name 只能使用小写英文字母、数字和下划线，并且必须以字母开头"
        )


def atomic_write_bytes(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(
        dir=path.parent, prefix=f".{path.name}.", delete=False
    ) as temporary:
        temporary.write(data)
        temporary_path = Path(temporary.name)
    temporary_path.replace(path)


def atomic_write_text(path: Path, text: str) -> None:
    atomic_write_bytes(path, text.encode("utf-8"))


def save_png_atomic(image: Image.Image, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(
        dir=path.parent, suffix=".png", prefix=f".{path.stem}.", delete=False
    ) as temporary:
        temporary_path = Path(temporary.name)
    try:
        image.save(temporary_path, format="PNG", optimize=True)
        temporary_path.replace(path)
    finally:
        temporary_path.unlink(missing_ok=True)


def standardize_image(
    source_path: Path,
    mode: str,
    target_size: tuple[int, int] = (TARGET_WIDTH, TARGET_HEIGHT),
) -> tuple[Image.Image, str]:
    with Image.open(source_path) as opened:
        image = ImageOps.exif_transpose(opened).convert("RGBA")

    target_width, target_height = target_size
    source_ratio = image.width / image.height
    target_ratio = target_width / target_height
    effective_mode = mode
    if mode == "auto":
        relative_difference = abs(source_ratio - target_ratio) / target_ratio
        effective_mode = "cover" if relative_difference <= 0.04 else "contain"

    if effective_mode == "cover":
        scale = max(target_width / image.width, target_height / image.height)
    else:
        scale = min(target_width / image.width, target_height / image.height)

    resized_size = (
        max(1, round(image.width * scale)),
        max(1, round(image.height * scale)),
    )
    resized = image.resize(resized_size, Image.Resampling.LANCZOS)

    if effective_mode == "cover":
        left = max(0, (resized.width - target_width) // 2)
        top = max(0, (resized.height - target_height) // 2)
        standardized = resized.crop(
            (left, top, left + target_width, top + target_height)
        )
    else:
        standardized = Image.new("RGBA", target_size, (0, 0, 0, 0))
        offset = (
            (target_width - resized.width) // 2,
            (target_height - resized.height) // 2,
        )
        standardized.alpha_composite(resized, offset)

    return standardized, effective_mode


def build_magenta_mask(image: Image.Image) -> Image.Image:
    red, green, blue, alpha = image.split()
    red_ok = red.point(lambda value: 255 if value >= 248 else 0)
    green_ok = green.point(lambda value: 255 if value <= 12 else 0)
    blue_ok = blue.point(lambda value: 255 if value >= 248 else 0)
    alpha_ok = alpha.point(lambda value: 255 if value >= 16 else 0)
    return ImageChops.multiply(
        ImageChops.multiply(red_ok, green_ok),
        ImageChops.multiply(blue_ok, alpha_ok),
    )


def build_dark_mask(image: Image.Image) -> Image.Image:
    rgb = image.convert("RGB")
    grayscale = ImageOps.grayscale(rgb)
    dark = grayscale.point(lambda value: 255 if value <= 58 else 0)
    alpha = image.getchannel("A").point(lambda value: 255 if value >= 80 else 0)
    return ImageChops.multiply(dark, alpha)


def connected_components(
    mask: Image.Image,
    *,
    minimum_pixels: int,
    maximum_components: int = 256,
) -> list[Component]:
    if mask.mode != "L":
        mask = mask.convert("L")
    width, height = mask.size
    data = mask.tobytes()
    visited = bytearray(width * height)
    components: list[Component] = []

    for start, value in enumerate(data):
        if value == 0 or visited[start]:
            continue
        queue: deque[int] = deque([start])
        visited[start] = 1
        count = 0
        min_x = max_x = start % width
        min_y = max_y = start // width

        while queue:
            index = queue.popleft()
            count += 1
            x = index % width
            y = index // width
            min_x = min(min_x, x)
            max_x = max(max_x, x)
            min_y = min(min_y, y)
            max_y = max(max_y, y)

            if x > 0:
                neighbor = index - 1
                if data[neighbor] and not visited[neighbor]:
                    visited[neighbor] = 1
                    queue.append(neighbor)
            if x + 1 < width:
                neighbor = index + 1
                if data[neighbor] and not visited[neighbor]:
                    visited[neighbor] = 1
                    queue.append(neighbor)
            if y > 0:
                neighbor = index - width
                if data[neighbor] and not visited[neighbor]:
                    visited[neighbor] = 1
                    queue.append(neighbor)
            if y + 1 < height:
                neighbor = index + width
                if data[neighbor] and not visited[neighbor]:
                    visited[neighbor] = 1
                    queue.append(neighbor)

        if count >= minimum_pixels:
            components.append(
                Component(
                    count=count,
                    bbox=(min_x, min_y, max_x, max_y),
                    seed=(start % width, start // width),
                )
            )
            if len(components) >= maximum_components:
                break

    return components


def estimate_corner_radius(
    mask: Image.Image, bbox: tuple[int, int, int, int]
) -> float:
    left, top, right, bottom = bbox
    crop = mask.crop((left, top, right + 1, bottom + 1))
    width, height = crop.size
    pixels = crop.load()
    estimates: list[float] = []

    for y in range(min(height, max(4, height // 2))):
        xs = [x for x in range(width) if pixels[x, y] > 0]
        if not xs:
            continue
        estimates.append(float(min(xs)))
        estimates.append(float(width - 1 - max(xs)))
        if len(xs) >= width - 2:
            estimates.append(float(y))
            break

    for x in range(min(width, max(4, width // 2))):
        ys = [y for y in range(height) if pixels[x, y] > 0]
        if not ys:
            continue
        estimates.append(float(min(ys)))
        estimates.append(float(height - 1 - max(ys)))
        if len(ys) >= height - 2:
            estimates.append(float(x))
            break

    positive = sorted(value for value in estimates if value > 0.5)
    if not positive:
        return 0.0
    median = positive[len(positive) // 2]
    return max(0.0, min(median, min(width, height) * 0.48))


def scaled_detection_mask(mask: Image.Image) -> Image.Image:
    return mask.resize(
        (
            max(1, round(mask.width * DETECTION_SCALE)),
            max(1, round(mask.height * DETECTION_SCALE)),
        ),
        Image.Resampling.NEAREST,
    )


def component_to_viewport(
    component: Component,
    mask: Image.Image,
    image_size: tuple[int, int],
    method: str,
) -> DetectedViewport:
    inverse_scale = 1 / DETECTION_SCALE
    radius = estimate_corner_radius(mask, component.bbox) * inverse_scale
    left, top, right, bottom = component.bbox
    full_left = left * inverse_scale
    full_top = top * inverse_scale
    full_right = (right + 1) * inverse_scale
    full_bottom = (bottom + 1) * inverse_scale

    inset = 2.0
    x = min(full_right, full_left + inset)
    y = min(full_bottom, full_top + inset)
    width = max(1.0, full_right - full_left - inset * 2)
    height = max(1.0, full_bottom - full_top - inset * 2)
    radius = max(0.0, radius - inset)
    return DetectedViewport(x, y, width, height, radius, method)


def detect_viewport(
    image: Image.Image,
    model_viewport: DetectedViewport | None = None,
) -> tuple[DetectedViewport, Image.Image, str | None]:
    magenta_mask = build_magenta_mask(image)
    small_magenta = scaled_detection_mask(magenta_mask)
    minimum_magenta = max(80, round(small_magenta.width * small_magenta.height * 0.00025))
    magenta_components = connected_components(
        small_magenta, minimum_pixels=minimum_magenta
    )
    if magenta_components:
        component = max(magenta_components, key=lambda item: item.count)
        viewport = component_to_viewport(
            component, small_magenta, image.size, "magenta"
        )
        return viewport, magenta_mask, None

    if model_viewport is not None:
        warning = (
            "提示：图中没有品红标记，已使用 OpenAI 视觉模型识别取景框。"
            "请检查标注预览图。"
        )
        return model_viewport, Image.new("L", image.size, 0), warning

    dark_mask = build_dark_mask(image)
    small_dark = scaled_detection_mask(dark_mask)
    minimum_dark = max(200, round(small_dark.width * small_dark.height * 0.001))
    candidates = connected_components(small_dark, minimum_pixels=minimum_dark)
    rectangular = [
        component
        for component in candidates
        if component.fill_ratio >= 0.62
        and component.width >= small_dark.width * 0.08
        and component.height >= small_dark.height * 0.035
        and 0.45 <= component.width / max(1, component.height) <= 2.6
    ]
    pool = rectangular or candidates
    if pool:
        component = max(pool, key=lambda item: item.width * item.height)
        viewport = component_to_viewport(
            component, small_dark, image.size, "dark_fallback"
        )
        warning = (
            "警告：OpenAI 未提供可用取景框，已退回“最大暗色矩形”检测。"
            "请检查标注预览图。"
        )
    else:
        # 最后的保守降级保证任意图片都能入库；不把失败转嫁给用户补坐标。
        viewport = DetectedViewport(
            x=image.width * 0.20,
            y=image.height * 0.18,
            width=image.width * 0.60,
            height=image.height * 0.32,
            corner_radius=image.width * 0.045,
            method="safe_default",
        )
        warning = (
            "警告：OpenAI 与本地几何检测都未找到可信取景框，"
            "已使用保守的中央自动窗口。请检查标注预览图。"
        )
    # 旧图的暗色可能也用于按钮、文字和阴影；只有拟合窗口可以被挖空，
    # 不能像品红标记一样在全图清理同色像素。
    no_global_cleanup = Image.new("L", image.size, 0)
    return viewport, no_global_cleanup, warning


def carve_viewport(
    image: Image.Image,
    viewport: DetectedViewport,
    detected_color_mask: Image.Image,
) -> Image.Image:
    body = image.copy()
    hole = Image.new("L", image.size, 0)
    draw = ImageDraw.Draw(hole)
    bounds = (
        round(viewport.x),
        round(viewport.y),
        round(viewport.x + viewport.width),
        round(viewport.y + viewport.height),
    )
    draw.rounded_rectangle(
        bounds,
        radius=max(0, round(viewport.corner_radius)),
        fill=255,
    )
    feathered_hole = hole.filter(ImageFilter.GaussianBlur(radius=1.25))

    # Exact marker pixels must never leak into the shipped skin.
    marker_cleanup = detected_color_mask.filter(ImageFilter.GaussianBlur(radius=0.65))
    removal = ImageChops.lighter(feathered_hole, marker_cleanup)
    preserved_alpha = ImageChops.multiply(
        body.getchannel("A"), ImageOps.invert(removal)
    )
    body.putalpha(preserved_alpha)
    return body


def image_data_url(image: Image.Image) -> str:
    with tempfile.SpooledTemporaryFile(max_size=8 * 1024 * 1024) as stream:
        image.save(stream, format="PNG", optimize=True)
        stream.seek(0)
        encoded = base64.b64encode(stream.read()).decode("ascii")
    return f"data:image/png;base64,{encoded}"


def vision_prompt() -> str:
    functions = " / ".join(ALLOWED_CONTROLS)
    return f"""
你是相机 UI 工业设计图的视觉标注器。输入图片可能是正视图、带轻微透视的产品图、
旧设计稿、透明 PNG 或带背景的图片，不要要求输入遵循特定颜色或模板。

第一项任务：识别真正显示实时画面的取景框或屏幕内部边界。
- viewport 使用整张图片的百分比坐标。
- x_pct、y_pct 是左上角，width_pct、height_pct 是尺寸。
- corner_radius_width_pct 是圆角半径占整张图片宽度的百分比。
- 若看不到可信取景框，viewport 必须返回 null，不要猜测。

第二项任务：只标注肉眼清晰、可独立点击的实体控件。
功能只能从以下枚举选择：{functions}
- shutter：拍照快门
- album：进入照片墙或相册
- flip：切换前后摄像头
- flash：闪光灯开关
- timer：5/10 秒定时
- drawer：打开相机/相纸选择抽屉

坐标规则：
1. 原点是整张图片左上角。
2. center_x_pct、center_y_pct、width_pct、height_pct 都是相对整张图片的 0 到 100 百分比。
3. 热区应覆盖按钮并略留可点击余量，但不要与相邻按钮重叠。
4. 看不清或不存在的功能必须省略，禁止猜测。
5. 装饰文字、镜头、取景框、Logo 不属于可交互控件。

返回内容必须符合请求中提供的 JSON Schema。
""".strip()


def vision_json_schema() -> dict[str, Any]:
    number_0_100 = {"type": "number", "minimum": 0, "maximum": 100}
    positive_percent = {
        "type": "number",
        "exclusiveMinimum": 0,
        "maximum": 100,
    }
    confidence = {"type": "number", "minimum": 0, "maximum": 1}
    viewport_object = {
        "type": "object",
        "properties": {
            "x_pct": number_0_100,
            "y_pct": number_0_100,
            "width_pct": positive_percent,
            "height_pct": positive_percent,
            "corner_radius_width_pct": number_0_100,
            "confidence": confidence,
        },
        "required": [
            "x_pct",
            "y_pct",
            "width_pct",
            "height_pct",
            "corner_radius_width_pct",
            "confidence",
        ],
        "additionalProperties": False,
    }
    control_object = {
        "type": "object",
        "properties": {
            "function": {"type": "string", "enum": list(ALLOWED_CONTROLS)},
            "center_x_pct": number_0_100,
            "center_y_pct": number_0_100,
            "width_pct": positive_percent,
            "height_pct": positive_percent,
            "confidence": confidence,
        },
        "required": [
            "function",
            "center_x_pct",
            "center_y_pct",
            "width_pct",
            "height_pct",
            "confidence",
        ],
        "additionalProperties": False,
    }
    return {
        "type": "object",
        "properties": {
            "viewport": {
                "anyOf": [
                    viewport_object,
                    {"type": "null"},
                ]
            },
            "controls": {
                "type": "array",
                "items": control_object,
                "maxItems": len(ALLOWED_CONTROLS),
            },
        },
        "required": ["viewport", "controls"],
        "additionalProperties": False,
    }


def extract_json_object(content: Any) -> dict[str, Any]:
    if isinstance(content, dict):
        return content
    if isinstance(content, list):
        text_parts = [
            item.get("text", "")
            for item in content
            if isinstance(item, dict) and item.get("type") == "text"
        ]
        content = "\n".join(text_parts)
    if not isinstance(content, str):
        raise ValueError("视觉模型返回内容不是字符串或 JSON 对象")

    text = content.strip()
    if text.startswith("```"):
        text = re.sub(r"^```(?:json)?\s*", "", text)
        text = re.sub(r"\s*```$", "", text)
    try:
        parsed = json.loads(text)
    except json.JSONDecodeError:
        start = text.find("{")
        end = text.rfind("}")
        if start < 0 or end <= start:
            raise ValueError("视觉模型没有返回可解析的 JSON") from None
        parsed = json.loads(text[start : end + 1])
    if not isinstance(parsed, dict):
        raise ValueError("视觉模型 JSON 顶层必须是对象")
    return parsed


def validate_controls(payload: dict[str, Any]) -> tuple[list[dict[str, Any]], list[str]]:
    raw_controls = payload.get("controls")
    if not isinstance(raw_controls, list):
        raise ValueError("视觉模型 JSON 缺少 controls 数组")

    validated: dict[str, dict[str, Any]] = {}
    errors: list[str] = []
    number_fields = (
        "center_x_pct",
        "center_y_pct",
        "width_pct",
        "height_pct",
    )
    for index, raw in enumerate(raw_controls):
        if not isinstance(raw, dict):
            errors.append(f"controls[{index}] 不是对象")
            continue
        function = raw.get("function")
        if function not in ALLOWED_CONTROLS:
            errors.append(f"controls[{index}] function 非法：{function!r}")
            continue
        try:
            values = {field: float(raw[field]) for field in number_fields}
            confidence = float(raw.get("confidence", 0.5))
        except (KeyError, TypeError, ValueError):
            errors.append(f"controls[{index}] 坐标或尺寸不是数字")
            continue
        if not all(0 <= values[field] <= 100 for field in ("center_x_pct", "center_y_pct")):
            errors.append(f"controls[{index}] 中心点超出 0...100")
            continue
        if not all(0 < values[field] <= 100 for field in ("width_pct", "height_pct")):
            errors.append(f"controls[{index}] 热区尺寸超出 0...100")
            continue
        left = values["center_x_pct"] - values["width_pct"] / 2
        right = values["center_x_pct"] + values["width_pct"] / 2
        top = values["center_y_pct"] - values["height_pct"] / 2
        bottom = values["center_y_pct"] + values["height_pct"] / 2
        if left < 0 or right > 100 or top < 0 or bottom > 100:
            errors.append(f"controls[{index}] 热区越过图片边界")
            continue
        if not 0 <= confidence <= 1:
            errors.append(f"controls[{index}] confidence 超出 0...1")
            continue

        control = {
            "function": function,
            **{key: round(value, 5) for key, value in values.items()},
            "confidence": round(confidence, 4),
        }
        previous = validated.get(function)
        if previous is None or control["confidence"] > previous["confidence"]:
            validated[function] = control

    if errors:
        raise ValueError("视觉模型 JSON 校验失败：\n- " + "\n- ".join(errors))
    controls = [validated[name] for name in ALLOWED_CONTROLS if name in validated]
    missing = [name for name in ALLOWED_CONTROLS if name not in validated]
    return controls, missing


def validate_model_viewport(
    payload: dict[str, Any],
    image_size: tuple[int, int],
) -> DetectedViewport | None:
    raw = payload.get("viewport")
    if raw is None:
        return None
    if not isinstance(raw, dict):
        raise ValueError("视觉模型 viewport 必须是对象或 null")

    fields = (
        "x_pct",
        "y_pct",
        "width_pct",
        "height_pct",
        "corner_radius_width_pct",
        "confidence",
    )
    try:
        values = {field: float(raw[field]) for field in fields}
    except (KeyError, TypeError, ValueError):
        raise ValueError("视觉模型 viewport 字段不完整或不是数字") from None

    x = values["x_pct"]
    y = values["y_pct"]
    width = values["width_pct"]
    height = values["height_pct"]
    radius = values["corner_radius_width_pct"]
    confidence = values["confidence"]
    if not (
        0 <= x <= 100
        and 0 <= y <= 100
        and 0 < width <= 100
        and 0 < height <= 100
        and x + width <= 100
        and y + height <= 100
        and 0 <= radius <= min(width, height) / 2
        and 0 <= confidence <= 1
    ):
        raise ValueError("视觉模型 viewport 坐标、尺寸或置信度越界")
    if confidence < 0.35:
        return None

    image_width, image_height = image_size
    inset = 2.0
    pixel_x = x / 100 * image_width + inset
    pixel_y = y / 100 * image_height + inset
    pixel_width = width / 100 * image_width - inset * 2
    pixel_height = height / 100 * image_height - inset * 2
    pixel_radius = max(0, radius / 100 * image_width - inset)
    if pixel_width < 8 or pixel_height < 8:
        return None
    return DetectedViewport(
        x=pixel_x,
        y=pixel_y,
        width=pixel_width,
        height=pixel_height,
        corner_radius=pixel_radius,
        method="openai_vision",
    )


def response_output_text(payload: dict[str, Any]) -> str:
    direct = payload.get("output_text")
    if isinstance(direct, str) and direct.strip():
        return direct
    for output in payload.get("output", []):
        if not isinstance(output, dict) or output.get("type") != "message":
            continue
        for content in output.get("content", []):
            if (
                isinstance(content, dict)
                and content.get("type") == "output_text"
                and isinstance(content.get("text"), str)
            ):
                return content["text"]
    raise ValueError("OpenAI 响应中没有 output_text")


def call_openai_vision(
    image: Image.Image,
    *,
    endpoint: str,
    model: str,
    api_key: str,
) -> tuple[DetectedViewport | None, list[dict[str, Any]], list[str]]:
    if requests is None:
        raise RuntimeError("缺少 requests；请安装后再启用视觉模型标注")
    payload = {
        "model": model,
        "input": [
            {
                "role": "user",
                "content": [
                    {"type": "input_text", "text": vision_prompt()},
                    {
                        "type": "input_image",
                        "image_url": image_data_url(image),
                        "detail": "high",
                    },
                ],
            }
        ],
        "store": False,
        "max_output_tokens": 2000,
        "reasoning": {"effort": "low"},
        "text": {
            "format": {
                "type": "json_schema",
                "name": "camera_skin_detection",
                "strict": True,
                "schema": vision_json_schema(),
            }
        },
    }
    headers = {
        "Authorization": f"Bearer {api_key}",
        "Content-Type": "application/json",
    }

    last_error: Exception | None = None
    for attempt in range(3):
        try:
            response = requests.post(
                endpoint,
                headers=headers,
                json=payload,
                timeout=(15, 120),
            )
            response.raise_for_status()
            response_payload = response.json()
            parsed = extract_json_object(response_output_text(response_payload))
            viewport = validate_model_viewport(parsed, image.size)
            controls, missing = validate_controls(parsed)
            return viewport, controls, missing
        except (requests.RequestException, ValueError, KeyError) as exc:
            last_error = exc
            if attempt < 2:
                time.sleep(1.5 * (attempt + 1))
    raise RuntimeError(
        f"OpenAI 视觉标注失败（已重试 3 次）：{last_error}"
    ) from last_error


def create_preview(
    image: Image.Image,
    viewport: DetectedViewport,
    controls: Iterable[dict[str, Any]],
) -> Image.Image:
    preview = image.convert("RGBA").copy()
    draw = ImageDraw.Draw(preview)
    line_width = max(4, preview.width // 260)
    viewport_bounds = (
        viewport.x,
        viewport.y,
        viewport.x + viewport.width,
        viewport.y + viewport.height,
    )
    draw.rounded_rectangle(
        viewport_bounds,
        radius=viewport.corner_radius,
        outline=(0, 255, 80, 255),
        width=line_width,
    )
    draw_label(
        draw,
        (viewport.x, max(0, viewport.y - 34)),
        f"VIEWFINDER ({viewport.method})",
        (0, 160, 50, 255),
    )

    for control in controls:
        center_x = control["center_x_pct"] / 100 * preview.width
        center_y = control["center_y_pct"] / 100 * preview.height
        width = control["width_pct"] / 100 * preview.width
        height = control["height_pct"] / 100 * preview.height
        bounds = (
            center_x - width / 2,
            center_y - height / 2,
            center_x + width / 2,
            center_y + height / 2,
        )
        draw.rectangle(bounds, outline=(255, 35, 35, 255), width=line_width)
        draw_label(
            draw,
            (bounds[0], max(0, bounds[1] - 30)),
            control["function"],
            (190, 0, 0, 255),
        )
    return preview


def draw_label(
    draw: ImageDraw.ImageDraw,
    origin: tuple[float, float],
    text: str,
    background: tuple[int, int, int, int],
) -> None:
    font = ImageFont.load_default()
    left, top, right, bottom = draw.textbbox(origin, text, font=font)
    padding = 5
    draw.rectangle(
        (left - padding, top - padding, right + padding, bottom + padding),
        fill=background,
    )
    draw.text(origin, text, fill=(255, 255, 255, 255), font=font)


def write_asset(
    assets_directory: Path,
    name: str,
    body: Image.Image,
) -> tuple[str, Path]:
    asset_name = f"skin_{name}_body"
    imageset = assets_directory / f"{asset_name}.imageset"
    imageset.mkdir(parents=True, exist_ok=True)
    for stale_png in imageset.glob("*.png"):
        stale_png.unlink()
    png_path = imageset / f"{asset_name}.png"
    save_png_atomic(body, png_path)
    contents = {
        "images": [
            {
                "filename": png_path.name,
                "idiom": "universal",
                "scale": "1x",
            }
        ],
        "info": {"author": "xcode", "version": 1},
    }
    atomic_write_text(
        imageset / "Contents.json",
        json.dumps(contents, ensure_ascii=False, indent=2) + "\n",
    )
    return asset_name, imageset


def swift_string(value: str) -> str:
    escaped = (
        value.replace("\\", "\\\\")
        .replace('"', '\\"')
        .replace("\n", "\\n")
        .replace("\r", "\\r")
        .replace("\t", "\\t")
    )
    return f'"{escaped}"'


def swift_float(value: Any) -> str:
    number = float(value)
    if not math.isfinite(number):
        raise ValueError("配置包含非有限数字")
    return f"{number / 100:.7f}".rstrip("0").rstrip(".")


def swift_color(hex_value: str) -> str:
    cleaned = hex_value.strip().lstrip("#")
    if len(cleaned) != 6:
        raise ValueError(f"颜色必须是 #RRGGBB：{hex_value}")
    try:
        red = int(cleaned[0:2], 16) / 255
        green = int(cleaned[2:4], 16) / 255
        blue = int(cleaned[4:6], 16) / 255
    except ValueError as exc:
        raise ValueError(f"颜色必须是 #RRGGBB：{hex_value}") from exc
    return (
        "Color("
        f"red: {red:.6f}, green: {green:.6f}, blue: {blue:.6f}"
        ")"
    )


def generate_swift(definitions: list[dict[str, Any]]) -> str:
    lines = [
        "// 此文件由 add_camera.py 自动生成；请勿手改。",
        "import SwiftUI",
        "",
        "/// 产品中生成皮肤热区允许触发的相机功能。",
        "enum CameraSkinControlFunction: String, CaseIterable {",
        *[f"    case {name}" for name in ALLOWED_CONTROLS],
        "}",
        "",
        "/// 产品中生成皮肤上的一个百分比点击热区。",
        "struct CameraSkinHotspot: Identifiable {",
        "    let id: String",
        "    let function: CameraSkinControlFunction",
        "    let centerX: CGFloat",
        "    let centerY: CGFloat",
        "    let width: CGFloat",
        "    let height: CGFloat",
        "}",
        "",
        "/// 产品中皮肤状态控件支持的交互类型。",
        "enum CameraSkinControlType: String {",
        "    case toggle",
        "}",
        "",
        "/// 产品中状态贴片相对整张机身图的百分比矩形。",
        "struct CameraSkinControlRect {",
        "    let x: CGFloat",
        "    let y: CGFloat",
        "    let width: CGFloat",
        "    let height: CGFloat",
        "}",
        "",
        "/// 产品中会随功能状态更换贴片的实体控件。",
        "struct CameraSkinControl: Identifiable {",
        "    let id: String",
        "    let role: CameraSkinControlFunction",
        "    let type: CameraSkinControlType",
        "    let rect: CameraSkinControlRect",
        "    let statePatches: [String: String]",
        "}",
        "",
        "/// 产品中生成皮肤自动检测出的透明取景框。",
        "struct CameraSkinViewfinderRect {",
        "    let x: CGFloat",
        "    let y: CGFloat",
        "    let width: CGFloat",
        "    let height: CGFloat",
        "    let cornerRadiusWidth: CGFloat",
        "}",
        "",
        "/// 产品中一套 CameraSkin 的 Core Image 调色参数，实时预览与成片共用。",
        "struct CameraSkinFilterParameters {",
        "    /// CIColorControls 饱和度；建议 0...2，1 为原图。",
        "    let saturation: Double",
        "    /// CIColorControls 对比度；建议 0.5...1.5，1 为原图。",
        "    let contrast: Double",
        "    /// CIColorControls 亮度；建议 -0.2...0.2，0 为原图。",
        "    let brightness: Double",
        "    /// CITemperatureAndTint 色温偏移；建议 -2000...2000 K，正值偏暖。",
        "    let temperatureShift: Double",
        "    /// CIColorMatrix 褪色量；建议 0...0.25，0 为关闭。",
        "    let fade: Double",
        "    /// CIVignette 暗角强度；建议 0...2，0 为关闭。",
        "    let vignetteIntensity: Double",
        "    /// CIVignette 暗角半径；Core Image 合理范围 0...2。",
        "    let vignetteRadius: Double",
        "    /// CIRandomGenerator 颗粒混合强度；建议 0...0.15，0 为关闭。",
        "    let grainIntensity: Double",
        "    /// 颗粒尺寸倍率；建议 0.5...3。",
        "    let grainSize: Double",
        "    /// CIBloom 高光溢出强度；建议 0...1，0 为关闭。",
        "    let bloomIntensity: Double",
        "    /// CIBloom 半径占短边比例；建议 0...0.05。",
        "    let bloomRadiusFraction: Double",
        "}",
        "",
        "/// 产品中一套相机皮肤可提供的相纸选项。",
        "struct CameraSkinPaper: Identifiable {",
        "    let id: String",
        "    let displayName: String",
        "    let colorHex: String",
        "}",
        "",
        "/// 产品中一套可直接显示并响应实体按键的完整相机皮肤。",
        "struct CameraSkin: Identifiable {",
        "    let id: String",
        "    let displayName: String",
        "    let thumbnailImage: String",
        "    let bodyImage: String",
        "    let pixelWidth: CGFloat",
        "    let pixelHeight: CGFloat",
        "    /// 顶条、机身槽、底条和抽屉共用的无缝画布色。",
        "    let canvasColor: Color",
        "    let viewfinderRect: CameraSkinViewfinderRect",
        "    let hotspots: [CameraSkinHotspot]",
        "    let controls: [CameraSkinControl]",
        "    let filter: CameraSkinFilterParameters",
        "    let papers: [CameraSkinPaper]",
        "}",
        "",
        "/// 产品中由 add_camera.py 重建的全部生成相机皮肤注册表。",
        "enum CameraSkins {",
        "    static let all: [CameraSkin] = [",
    ]

    for definition in definitions:
        viewport = definition["viewport"]
        filter_parameters = definition.get("filter", {})
        papers = definition.get(
            "papers",
            [
                {"id": "classic", "display_name": "经典白", "color_hex": "#FFFFFF"},
                {"id": "barbie", "display_name": "芭比粉", "color_hex": "#F573B3"},
                {"id": "lemon", "display_name": "柠檬黄", "color_hex": "#FCE147"},
                {"id": "sky", "display_name": "晴空蓝", "color_hex": "#66E8FA"},
                {"id": "noir", "display_name": "夜幕黑", "color_hex": "#1C1A17"},
            ],
        )
        lines.extend(
            [
                "        CameraSkin(",
                f"            id: {swift_string(definition['name'])},",
                f"            displayName: {swift_string(definition['display_name'])},",
                "            thumbnailImage: "
                f"{swift_string(definition.get('thumbnail_asset_name', definition['asset_name']))},",
                f"            bodyImage: {swift_string(definition['asset_name'])},",
                f"            pixelWidth: {int(definition['pixel_width'])},",
                f"            pixelHeight: {int(definition['pixel_height'])},",
                "            canvasColor: "
                f"{swift_color(definition.get('canvas_color', definition.get('top_bar_color', '#F4F4F4')))},",
                "            viewfinderRect: CameraSkinViewfinderRect(",
                f"                x: {swift_float(viewport['x'])},",
                f"                y: {swift_float(viewport['y'])},",
                f"                width: {swift_float(viewport['width'])},",
                f"                height: {swift_float(viewport['height'])},",
                "                cornerRadiusWidth: "
                f"{swift_float(viewport['corner_radius_width'])}",
                "            ),",
                "            hotspots: [",
            ]
        )
        for index, control in enumerate(definition["controls"]):
            hotspot_id = (
                f"{definition['name']}.{control['function']}.{index}"
            )
            lines.extend(
                [
                    "                CameraSkinHotspot(",
                    f"                    id: {swift_string(hotspot_id)},",
                    f"                    function: .{control['function']},",
                    f"                    centerX: {swift_float(control['center_x_pct'])},",
                    f"                    centerY: {swift_float(control['center_y_pct'])},",
                    f"                    width: {swift_float(control['width_pct'])},",
                    f"                    height: {swift_float(control['height_pct'])}",
                    "                ),",
                ]
            )
        state_controls = definition.get("state_controls", [])
        lines.extend(["            ],", "            controls: ["])
        for index, control in enumerate(state_controls):
            control_id = (
                f"{definition['name']}.{control['role']}.state.{index}"
            )
            control_rect = control["rect"]
            state_patches = control.get("state_patches", {})
            patch_entries = ", ".join(
                f"{swift_string(key)}: {swift_string(value)}"
                for key, value in sorted(state_patches.items())
            )
            lines.extend(
                [
                    "                CameraSkinControl(",
                    f"                    id: {swift_string(control_id)},",
                    f"                    role: .{control['role']},",
                    f"                    type: .{control['type']},",
                    "                    rect: CameraSkinControlRect(",
                    f"                        x: {swift_float(control_rect['x'])},",
                    f"                        y: {swift_float(control_rect['y'])},",
                    f"                        width: {swift_float(control_rect['width'])},",
                    f"                        height: {swift_float(control_rect['height'])}",
                    "                    ),",
                    f"                    statePatches: [{patch_entries}]",
                    "                ),",
                ]
            )
        lines.extend(
            [
                "            ],",
                "            filter: CameraSkinFilterParameters(",
                f"                saturation: {float(filter_parameters.get('saturation', 1.0))},",
                f"                contrast: {float(filter_parameters.get('contrast', 1.0))},",
                f"                brightness: {float(filter_parameters.get('brightness', 0.0))},",
                "                temperatureShift: "
                f"{float(filter_parameters.get('temperature_shift', 0.0))},",
                f"                fade: {float(filter_parameters.get('fade', 0.0))},",
                "                vignetteIntensity: "
                f"{float(filter_parameters.get('vignette_intensity', 0.0))},",
                "                vignetteRadius: "
                f"{float(filter_parameters.get('vignette_radius', 1.0))},",
                "                grainIntensity: "
                f"{float(filter_parameters.get('grain_intensity', 0.0))},",
                f"                grainSize: {float(filter_parameters.get('grain_size', 1.0))},",
                "                bloomIntensity: "
                f"{float(filter_parameters.get('bloom_intensity', 0.0))},",
                "                bloomRadiusFraction: "
                f"{float(filter_parameters.get('bloom_radius_fraction', 0.0))}",
                "            ),",
                "            papers: [",
            ]
        )
        for paper in papers:
            lines.extend(
                [
                    "                CameraSkinPaper(",
                    f"                    id: {swift_string(paper['id'])},",
                    f"                    displayName: {swift_string(paper['display_name'])},",
                    f"                    colorHex: {swift_string(paper['color_hex'])}",
                    "                ),",
                ]
            )
        lines.extend(["            ]", "        ),"])

    lines.extend(
        [
            "    ]",
            "",
            "    static func named(_ name: String?) -> CameraSkin? {",
            "        guard let name else { return nil }",
            "        return all.first { $0.id == name }",
            "    }",
            "}",
            "",
        ]
    )
    return "\n".join(lines)


def load_definitions(definitions_directory: Path) -> list[dict[str, Any]]:
    definitions = []
    if definitions_directory.exists():
        for path in sorted(definitions_directory.glob("*.json")):
            with path.open("r", encoding="utf-8") as handle:
                definition = json.load(handle)
            if isinstance(definition, dict):
                definitions.append(definition)
    definitions.sort(key=lambda item: item["name"])
    return definitions


def run(args: argparse.Namespace) -> int:
    project_root = args.project_root.expanduser().resolve()
    app_directory = project_root / "MoodPolaroid"
    assets_directory = app_directory / "Assets.xcassets"
    registry_directory = app_directory / "CameraSkins"
    definitions_directory = registry_directory / "definitions"
    previews_directory = registry_directory / "previews"
    swift_path = app_directory / "CameraSkins.swift"
    if not assets_directory.is_dir():
        raise FileNotFoundError(f"找不到 Assets.xcassets：{assets_directory}")

    if args.rebuild_registry:
        definitions = load_definitions(definitions_directory)
        atomic_write_text(swift_path, generate_swift(definitions))
        print(f"已根据 {definitions_directory} 重建：{swift_path}")
        return 0

    if Image is None:
        raise RuntimeError(
            "缺少依赖。请先运行：python -m pip install Pillow requests"
        )

    if args.image is None or not args.name or not args.display:
        raise ValueError("新增相机时必须提供图片、--name 和 --display")
    validate_name(args.name)
    source_path = args.image.expanduser().resolve()
    if not source_path.is_file():
        raise FileNotFoundError(f"找不到输入图片：{source_path}")

    print(f"[1/5] 标准化到 {TARGET_WIDTH}×{TARGET_HEIGHT}，保留透明通道")
    standardized, effective_mode = standardize_image(source_path, args.fit)
    print(f"      使用模式：{effective_mode}")

    print(f"[2/5] 使用 {args.model} 理解取景框与实体按键")
    model_viewport: DetectedViewport | None = None
    controls: list[dict[str, Any]] = []
    missing = list(ALLOWED_CONTROLS)
    if args.skip_vision:
        print(
            "      提示：已使用 --skip-vision，转入纯本地降级链路",
            file=sys.stderr,
        )
    else:
        api_key = os.getenv("OPENAI_API_KEY")
        if not api_key:
            print(
                "      警告：没有找到 OPENAI_API_KEY，"
                "将继续使用本地取景框检测；按键热区暂不生成。",
                file=sys.stderr,
            )
        else:
            try:
                model_viewport, controls, missing = call_openai_vision(
                    standardized,
                    endpoint=args.endpoint,
                    model=args.model,
                    api_key=api_key,
                )
            except RuntimeError as exc:
                print(
                    f"      警告：{exc}；将继续使用本地降级链路。",
                    file=sys.stderr,
                )
    print(
        "      模型取景框："
        f"{'已识别' if model_viewport is not None else '未识别，使用本地降级'}"
    )
    print(f"      已识别按键：{', '.join(item['function'] for item in controls) or '无'}")
    print(f"      未找到按键：{', '.join(missing) or '无'}")

    print("[3/5] 自动确定并挖空取景框")
    viewport, detection_mask, warning = detect_viewport(
        standardized,
        model_viewport=model_viewport,
    )
    if warning:
        print(f"      {warning}", file=sys.stderr)
    body = carve_viewport(standardized, viewport, detection_mask)
    print(
        "      取景框："
        f"x={viewport.x:.1f}, y={viewport.y:.1f}, "
        f"w={viewport.width:.1f}, h={viewport.height:.1f}, "
        f"r={viewport.corner_radius:.1f}"
    )

    print("[4/5] 写入 Assets.xcassets 并重建 CameraSkins.swift")
    asset_name, imageset = write_asset(assets_directory, args.name, body)
    definition_path = definitions_directory / f"{args.name}.json"
    existing_definition: dict[str, Any] = {}
    if definition_path.is_file():
        with definition_path.open("r", encoding="utf-8") as handle:
            loaded_definition = json.load(handle)
        if isinstance(loaded_definition, dict):
            existing_definition = loaded_definition

    definition = {
        "schema_version": 1,
        "name": args.name,
        "display_name": args.display,
        "asset_name": asset_name,
        "pixel_width": body.width,
        "pixel_height": body.height,
        "canvas_color": existing_definition.get("canvas_color", "#F4F4F4"),
        "standardization_mode": effective_mode,
        "vision_model": args.model if not args.skip_vision else None,
        "viewport_detection": viewport.method,
        "viewport": viewport.as_percent_dict(body.width, body.height),
        "controls": controls,
        "missing_controls": missing,
        "source_file": source_path.name,
        "filter": existing_definition.get("filter", {}),
        "papers": existing_definition.get("papers", []),
    }
    definitions_directory.mkdir(parents=True, exist_ok=True)
    atomic_write_text(
        definition_path,
        json.dumps(definition, ensure_ascii=False, indent=2) + "\n",
    )
    definitions = load_definitions(definitions_directory)
    atomic_write_text(swift_path, generate_swift(definitions))
    print(f"      资源：{imageset}")
    print(f"      配置：{definition_path}")
    print(f"      Swift：{swift_path}")

    print("[5/5] 输出标注验收图")
    preview = create_preview(standardized, viewport, controls)
    preview_path = previews_directory / f"{args.name}__annotated.png"
    save_png_atomic(preview, preview_path)
    print(f"      验收图：{preview_path}")
    print(f"完成：{args.display}（{args.name}）已可在 App 的皮肤选择中使用。")
    return 0


def main() -> int:
    try:
        return run(parse_args())
    except (FileNotFoundError, RuntimeError, ValueError) as exc:
        print(f"错误：{exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
