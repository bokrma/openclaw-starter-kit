"""Seed Mission Control boards/groups/tags/fields/webhooks/tasks/memory from env JSON.

This script is designed to run inside the Mission Control backend container.
It supports:
- legacy single-board seeding (OPENCLAW_MISSION_CONTROL_BOARD_* envs)
- multi-board pack seeding (OPENCLAW_MISSION_CONTROL_BOARD_PACK_* envs)
"""

from __future__ import annotations

import base64
import json
import os
import re
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from typing import Any

BASE_URL = "http://127.0.0.1:8000/api/v1"

MARKER_WEBHOOK = "seed-webhook"
MARKER_TASK = "seed-task"
MARKER_MEMORY = "seed"

headers = {
    "Authorization": "",
    "Content-Type": "application/json",
}


class SeedError(RuntimeError):
    """Raised when seed input or remote API calls fail."""


@dataclass
class SeedSummary:
    mode: str
    groups: list[dict[str, str]]
    boards: list[dict[str, str]]
    tags: list[dict[str, str]]
    custom_fields: list[dict[str, str]]
    webhooks: list[dict[str, str]]
    starter_memory: list[dict[str, str]]
    starter_tasks: list[dict[str, str]]
    group_memory: list[dict[str, str]]

    def as_dict(self) -> dict[str, object]:
        return {
            "mode": self.mode,
            "groups": self.groups,
            "boards": self.boards,
            "tags": self.tags,
            "custom_fields": self.custom_fields,
            "webhooks": self.webhooks,
            "starter_memory": self.starter_memory,
            "starter_tasks": self.starter_tasks,
            "group_memory": self.group_memory,
        }


def env(name: str, default: str = "") -> str:
    return (os.environ.get(name) or default).strip()


def parse_bool(raw: object, default: bool = False) -> bool:
    if raw is None:
        return default
    if isinstance(raw, bool):
        return raw
    text = str(raw).strip().lower()
    if text == "":
        return default
    return text in {"1", "true", "yes", "on"}


def parse_int(raw: object, default: int) -> int:
    if raw is None:
        return default
    if isinstance(raw, int):
        return raw
    text = str(raw).strip()
    if text == "":
        return default
    try:
        return int(text)
    except ValueError:
        return default


def slugify(value: object, fallback: str) -> str:
    normalized = re.sub(r"[^a-z0-9]+", "-", str(value or "").strip().lower()).strip("-")
    return normalized or fallback


def decode_json_b64(name: str) -> dict[str, object]:
    raw = env(name)
    if not raw:
        return {}
    try:
        parsed = json.loads(base64.b64decode(raw).decode("utf-8"))
    except Exception as exc:
        raise SeedError(f"invalid {name} JSON: {exc}") from exc
    if not isinstance(parsed, dict):
        raise SeedError(f"{name} must decode to a JSON object")
    return parsed


def request_json(
    method: str,
    path: str,
    *,
    query: dict[str, object] | None = None,
    payload: dict[str, object] | list[object] | None = None,
    expected_codes: tuple[int, ...] = (200,),
) -> tuple[int, Any]:
    url = f"{BASE_URL}{path}"
    if query:
        url = f"{url}?{urllib.parse.urlencode(query)}"
    data = None
    if payload is not None:
        data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(url, data=data, method=method, headers=headers)
    try:
        # BASE_URL is fixed to local Mission Control API, so urlopen is scoped to trusted HTTP endpoints.
        with urllib.request.urlopen(req, timeout=30) as resp:  # nosec B310
            status = resp.getcode()
            raw = resp.read().decode("utf-8")
            parsed = json.loads(raw) if raw else {}
            if status not in expected_codes:
                raise SeedError(f"{method} {path} returned {status}, expected {expected_codes}")
            return status, parsed
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", errors="ignore") if exc.fp else ""
        detail = body.strip() or exc.reason
        raise SeedError(f"{method} {path} failed ({exc.code}): {detail}") from exc


def fetch_all(path: str, *, query: dict[str, object] | None = None, limit: int = 200) -> list[dict[str, object]]:
    merged_query = dict(query or {})
    offset = 0
    items: list[dict[str, object]] = []
    while True:
        page_query = dict(merged_query)
        page_query["limit"] = str(limit)
        page_query["offset"] = str(offset)
        _, payload = request_json("GET", path, query=page_query)
        page_items = payload.get("items") if isinstance(payload, dict) else []
        if not isinstance(page_items, list):
            page_items = []
        normalized = [item for item in page_items if isinstance(item, dict)]
        items.extend(normalized)
        if len(normalized) < limit:
            break
        offset += limit
    return items


def normalize_json_object(raw: object | None, *, field_name: str) -> dict[str, object] | None:
    if raw is None:
        return None
    if isinstance(raw, dict):
        return raw
    if isinstance(raw, str):
        text = raw.strip()
        if not text:
            return None
        try:
            parsed = json.loads(text)
        except json.JSONDecodeError as exc:
            raise SeedError(f"invalid {field_name} JSON: {exc}") from exc
        if not isinstance(parsed, dict):
            raise SeedError(f"{field_name} must decode to a JSON object")
        return parsed
    raise SeedError(f"{field_name} must be a JSON object")


def append_perspective(description: str, perspective: str | None) -> str:
    clean_description = (description or "").strip()
    clean_perspective = (perspective or "").strip()
    if not clean_perspective:
        return clean_description
    perspective_block = f"Perspective:\n{clean_perspective}"
    if perspective_block in clean_description:
        return clean_description
    if clean_description:
        return f"{clean_description}\n\n{perspective_block}"
    return perspective_block


def resolve_gateway_id(
    gateways: list[dict[str, object]],
    *,
    gateway_id_hint: str,
    gateway_name_hint: str,
    gateway_url_hint: str,
) -> str:
    if gateway_id_hint:
        return gateway_id_hint
    selected: dict[str, object] | None = None
    for item in gateways:
        if gateway_url_hint and item.get("url") == gateway_url_hint:
            selected = item
            break
        if gateway_name_hint and item.get("name") == gateway_name_hint:
            selected = item
            break
    if selected is None and gateways:
        selected = gateways[0]
    if selected is None:
        raise SeedError("cannot seed board(s): no gateway found in Mission Control")
    gateway_id = str(selected.get("id") or "").strip()
    if not gateway_id:
        raise SeedError("cannot seed board(s): selected gateway has empty id")
    return gateway_id


def marker_text(kind: str, key: str) -> str:
    clean_key = slugify(key, "item")
    return f"[{kind}:{clean_key}]"


def ensure_marker_in_description(description: str, *, kind: str, key: str) -> str:
    marker = marker_text(kind, key)
    clean = (description or "").strip()
    if marker in clean:
        return clean
    if clean:
        return f"{clean}\n\n{marker}"
    return marker


def find_by_slug_or_name(items: list[dict[str, object]], *, slug: str, name: str) -> dict[str, object] | None:
    for item in items:
        if item.get("slug") == slug or item.get("name") == name:
            return item
    return None


def must_str(value: object | None, default: str = "") -> str:
    return str(value or default).strip()


def build_single_board_payload(
    *,
    config: dict[str, object],
    gateway_id: str,
) -> dict[str, object]:
    name = must_str(config.get("name"), "Main Board") or "Main Board"
    slug = must_str(config.get("slug")) or slugify(name, "main-board")
    description = must_str(config.get("description"), "Primary board for OpenClaw automation.")
    perspective = must_str(config.get("perspective"))
    description = append_perspective(description, perspective)

    board_type = must_str(config.get("board_type"), "goal") or "goal"
    goal_confirmed = parse_bool(config.get("goal_confirmed"), False)
    max_agents = parse_int(config.get("max_agents"), 1)
    objective = config.get("objective")
    target_date = config.get("target_date")
    goal_source = config.get("goal_source")
    board_group_id = config.get("board_group_id") or config.get("group_id")
    success_metrics = normalize_json_object(config.get("success_metrics"), field_name="success_metrics")
    success_metrics_env = normalize_json_object(
        config.get("success_metrics_json"),
        field_name="success_metrics_json",
    )
    if success_metrics is None and success_metrics_env is not None:
        success_metrics = success_metrics_env

    payload: dict[str, object] = {
        "name": name,
        "slug": slug,
        "description": description,
        "gateway_id": gateway_id,
        "board_type": board_type,
        "goal_confirmed": goal_confirmed,
        "max_agents": max_agents,
    }
    if objective:
        payload["objective"] = must_str(objective)
    if success_metrics is not None:
        payload["success_metrics"] = success_metrics
    if target_date:
        payload["target_date"] = must_str(target_date)
    if goal_source:
        payload["goal_source"] = must_str(goal_source)
    if board_group_id:
        payload["board_group_id"] = must_str(board_group_id)
    return payload


def upsert_group(
    *,
    item: dict[str, object],
    groups: list[dict[str, object]],
) -> tuple[str, str]:
    name = must_str(item.get("name"))
    if not name:
        raise SeedError("group.name is required")
    slug = must_str(item.get("slug")) or slugify(name, "group")
    payload: dict[str, object] = {
        "name": name,
        "slug": slug,
        "description": must_str(item.get("description")),
    }
    existing = find_by_slug_or_name(groups, slug=slug, name=name)
    if existing and existing.get("id"):
        group_id = must_str(existing.get("id"))
        request_json("PATCH", f"/board-groups/{group_id}", payload=payload)
        action = "updated"
    else:
        _, created = request_json("POST", "/board-groups", payload=payload)
        group_id = must_str(created.get("id"))
        action = "created"
        groups.append({"id": group_id, "slug": slug, "name": name})
    if not group_id:
        raise SeedError(f"group upsert failed for slug={slug}")
    return group_id, action


def upsert_board(
    *,
    item: dict[str, object],
    boards: list[dict[str, object]],
    default_gateway_id: str,
    group_ids_by_slug: dict[str, str],
) -> tuple[dict[str, object], str]:
    name = must_str(item.get("name"))
    if not name:
        raise SeedError("board.name is required")
    slug = must_str(item.get("slug")) or slugify(name, "board")
    description = must_str(item.get("description"), "Board context")
    perspective = must_str(item.get("perspective"))
    description = append_perspective(description, perspective)
    board_type = must_str(item.get("board_type"), "goal") or "goal"
    goal_confirmed = parse_bool(item.get("goal_confirmed"), False)
    max_agents = parse_int(item.get("max_agents"), 1)
    gateway_id = must_str(item.get("gateway_id")) or default_gateway_id

    group_slug = must_str(item.get("group_slug") or item.get("board_group_slug"))
    board_group_id = must_str(item.get("board_group_id"))
    if not board_group_id and group_slug:
        board_group_id = must_str(group_ids_by_slug.get(group_slug))
    if group_slug and not board_group_id:
        raise SeedError(f"board {slug} references unknown group_slug={group_slug}")

    success_metrics = normalize_json_object(item.get("success_metrics"), field_name=f"{slug}.success_metrics")
    payload: dict[str, object] = {
        "name": name,
        "slug": slug,
        "description": description,
        "gateway_id": gateway_id,
        "board_type": board_type,
        "goal_confirmed": goal_confirmed,
        "max_agents": max_agents,
    }
    for field in (
        "objective",
        "target_date",
        "goal_source",
        "require_approval_for_done",
        "require_review_before_done",
        "block_status_changes_with_pending_approval",
        "only_lead_can_change_status",
    ):
        if field in item and item.get(field) is not None:
            payload[field] = item.get(field)
    if success_metrics is not None:
        payload["success_metrics"] = success_metrics
    if board_group_id:
        payload["board_group_id"] = board_group_id

    existing = find_by_slug_or_name(boards, slug=slug, name=name)
    if existing and existing.get("id"):
        board_id = must_str(existing.get("id"))
        _, board_payload = request_json("PATCH", f"/boards/{board_id}", payload=payload)
        action = "updated"
    else:
        _, board_payload = request_json("POST", "/boards", payload=payload)
        action = "created"

    board_id = must_str(board_payload.get("id")) or must_str(existing.get("id") if existing else "")
    board_name = must_str(board_payload.get("name"), name) or name
    board_slug = must_str(board_payload.get("slug"), slug) or slug
    if not board_id:
        raise SeedError(f"board upsert failed for slug={slug}")

    if existing:
        existing["id"] = board_id
        existing["name"] = board_name
        existing["slug"] = board_slug
    else:
        boards.append({"id": board_id, "name": board_name, "slug": board_slug})
    return {"id": board_id, "name": board_name, "slug": board_slug}, action


def upsert_tag(
    *,
    item: dict[str, object],
    tags: list[dict[str, object]],
) -> tuple[str, str, str]:
    name = must_str(item.get("name"))
    if not name:
        raise SeedError("tag.name is required")
    slug = must_str(item.get("slug")) or slugify(name, "tag")
    payload: dict[str, object] = {"name": name, "slug": slug}
    if item.get("color") is not None:
        payload["color"] = must_str(item.get("color"))
    if item.get("description") is not None:
        payload["description"] = must_str(item.get("description"))
    existing = find_by_slug_or_name(tags, slug=slug, name=name)
    if existing and existing.get("id"):
        tag_id = must_str(existing.get("id"))
        _, result = request_json("PATCH", f"/tags/{tag_id}", payload=payload)
        action = "updated"
    else:
        _, result = request_json("POST", "/tags", payload=payload)
        action = "created"
    tag_id = must_str(result.get("id")) or must_str(existing.get("id") if existing else "")
    tag_name = must_str(result.get("name"), name) or name
    tag_slug = must_str(result.get("slug"), slug) or slug
    if not tag_id:
        raise SeedError(f"tag upsert failed for slug={slug}")
    if existing:
        existing["id"] = tag_id
        existing["name"] = tag_name
        existing["slug"] = tag_slug
    else:
        tags.append({"id": tag_id, "name": tag_name, "slug": tag_slug})
    return tag_id, tag_slug, action


def resolve_board_ids(
    *,
    board_slugs: list[str],
    board_ids_by_slug: dict[str, str],
    field_key: str,
) -> list[str]:
    ids: list[str] = []
    for slug in board_slugs:
        board_id = must_str(board_ids_by_slug.get(slug))
        if not board_id:
            raise SeedError(f"custom field {field_key} references unknown board slug={slug}")
        ids.append(board_id)
    deduped: list[str] = []
    seen: set[str] = set()
    for board_id in ids:
        if board_id in seen:
            continue
        seen.add(board_id)
        deduped.append(board_id)
    if not deduped:
        raise SeedError(f"custom field {field_key} has no board bindings")
    return deduped


def upsert_custom_field(
    *,
    item: dict[str, object],
    existing_fields: list[dict[str, object]],
    board_ids_by_slug: dict[str, str],
) -> tuple[str, str]:
    field_key = must_str(item.get("field_key"))
    if not field_key:
        raise SeedError("custom_fields[].field_key is required")
    board_slugs_raw = item.get("board_slugs")
    if not isinstance(board_slugs_raw, list) or not board_slugs_raw:
        raise SeedError(f"custom field {field_key} requires board_slugs[]")
    board_slugs = [must_str(value) for value in board_slugs_raw if must_str(value)]
    board_ids = resolve_board_ids(
        board_slugs=board_slugs,
        board_ids_by_slug=board_ids_by_slug,
        field_key=field_key,
    )

    payload: dict[str, object] = {
        "board_ids": board_ids,
    }
    for key in (
        "label",
        "field_type",
        "ui_visibility",
        "validation_regex",
        "description",
        "required",
        "default_value",
    ):
        if item.get(key) is not None:
            payload[key] = item.get(key)
    existing = next(
        (entry for entry in existing_fields if must_str(entry.get("field_key")) == field_key),
        None,
    )
    if existing and existing.get("id"):
        field_id = must_str(existing.get("id"))
        request_json("PATCH", f"/organizations/me/custom-fields/{field_id}", payload=payload)
        action = "updated"
    else:
        create_payload = dict(payload)
        create_payload["field_key"] = field_key
        if "label" not in create_payload:
            create_payload["label"] = field_key
        _, result = request_json("POST", "/organizations/me/custom-fields", payload=create_payload)
        field_id = must_str(result.get("id"))
        action = "created"
    if not field_id:
        raise SeedError(f"custom field upsert failed for field_key={field_key}")
    return field_key, action


def find_webhook_by_seed_key(items: list[dict[str, object]], *, seed_key: str) -> dict[str, object] | None:
    marker = marker_text(MARKER_WEBHOOK, seed_key)
    for item in items:
        description = must_str(item.get("description"))
        if marker in description:
            return item
    return None


def upsert_webhook(
    *,
    item: dict[str, object],
    board_id: str,
    webhooks: list[dict[str, object]],
) -> tuple[str, str, str, str]:
    seed_key = must_str(item.get("key"))
    if not seed_key:
        raise SeedError("webhooks[].key is required")
    description = ensure_marker_in_description(
        must_str(item.get("description")),
        kind=MARKER_WEBHOOK,
        key=seed_key,
    )
    payload: dict[str, object] = {
        "description": description,
        "enabled": parse_bool(item.get("enabled"), True),
    }
    if item.get("agent_id") is not None:
        payload["agent_id"] = must_str(item.get("agent_id")) or None

    existing = find_webhook_by_seed_key(webhooks, seed_key=seed_key)
    if existing and existing.get("id"):
        webhook_id = must_str(existing.get("id"))
        _, result = request_json("PATCH", f"/boards/{board_id}/webhooks/{webhook_id}", payload=payload)
        action = "updated"
    else:
        _, result = request_json("POST", f"/boards/{board_id}/webhooks", payload=payload)
        webhook_id = must_str(result.get("id"))
        action = "created"
    endpoint_url = must_str(result.get("endpoint_url"))
    if not webhook_id:
        raise SeedError(f"webhook upsert failed for key={seed_key}")
    return seed_key, webhook_id, endpoint_url, action


def list_seeded_board_memory_keys(items: list[dict[str, object]]) -> set[str]:
    keys: set[str] = set()
    for item in items:
        tags = item.get("tags")
        if not isinstance(tags, list):
            continue
        for tag in tags:
            text = must_str(tag)
            if text.startswith(f"{MARKER_MEMORY}:"):
                keys.add(text.split(":", 1)[1])
    return keys


def list_seeded_group_memory_keys(items: list[dict[str, object]]) -> set[str]:
    return list_seeded_board_memory_keys(items)


def ensure_seed_tag(tags: list[str] | None, *, seed_key: str) -> list[str]:
    normalized = [must_str(tag) for tag in (tags or []) if must_str(tag)]
    marker = f"{MARKER_MEMORY}:{slugify(seed_key, 'item')}"
    if marker not in normalized:
        normalized.append(marker)
    return normalized


def upsert_board_memory(
    *,
    item: dict[str, object],
    board_id: str,
    seeded_keys: set[str],
) -> tuple[str, str]:
    seed_key = must_str(item.get("key"))
    if not seed_key:
        raise SeedError("starter_memory[].key is required")
    normalized_key = slugify(seed_key, "memory")
    if normalized_key in seeded_keys:
        return normalized_key, "unchanged"
    content = must_str(item.get("content"))
    if not content:
        raise SeedError(f"starter_memory[{seed_key}] content is required")
    tags = ensure_seed_tag(item.get("tags") if isinstance(item.get("tags"), list) else None, seed_key=normalized_key)
    payload: dict[str, object] = {
        "content": content,
        "tags": tags,
        "source": must_str(item.get("source"), "starter-pack"),
    }
    request_json("POST", f"/boards/{board_id}/memory", payload=payload)
    return normalized_key, "created"


def upsert_group_memory(
    *,
    item: dict[str, object],
    group_id: str,
    seeded_keys: set[str],
) -> tuple[str, str]:
    seed_key = must_str(item.get("key"))
    if not seed_key:
        raise SeedError("group_memory[].key is required")
    normalized_key = slugify(seed_key, "group-memory")
    if normalized_key in seeded_keys:
        return normalized_key, "unchanged"
    content = must_str(item.get("content"))
    if not content:
        raise SeedError(f"group_memory[{seed_key}] content is required")
    tags = ensure_seed_tag(item.get("tags") if isinstance(item.get("tags"), list) else None, seed_key=normalized_key)
    payload: dict[str, object] = {
        "content": content,
        "tags": tags,
        "source": must_str(item.get("source"), "starter-pack"),
    }
    request_json("POST", f"/board-groups/{group_id}/memory", payload=payload)
    return normalized_key, "created"


def task_description_with_marker(description: str, *, seed_key: str) -> str:
    marker = marker_text(MARKER_TASK, seed_key)
    clean = (description or "").strip()
    if marker in clean:
        return clean
    if clean:
        return f"{clean}\n\n{marker}"
    return marker


def find_task_by_seed_key(tasks: list[dict[str, object]], *, seed_key: str) -> dict[str, object] | None:
    marker = marker_text(MARKER_TASK, seed_key)
    for task in tasks:
        description = must_str(task.get("description"))
        if marker in description:
            return task
    return None


def upsert_board_task(
    *,
    item: dict[str, object],
    board_id: str,
    existing_tasks: list[dict[str, object]],
    tag_ids_by_slug: dict[str, str],
) -> tuple[str, str, str]:
    seed_key = must_str(item.get("key"))
    if not seed_key:
        raise SeedError("starter_tasks[].key is required")
    normalized_key = slugify(seed_key, "task")
    title = must_str(item.get("title"))
    if not title:
        raise SeedError(f"starter_tasks[{seed_key}] title is required")
    description = task_description_with_marker(
        must_str(item.get("description")),
        seed_key=normalized_key,
    )
    payload: dict[str, object] = {
        "title": title,
        "description": description,
        "status": must_str(item.get("status"), "inbox") or "inbox",
        "priority": must_str(item.get("priority"), "medium") or "medium",
    }
    if item.get("due_at") is not None:
        payload["due_at"] = must_str(item.get("due_at"))
    if item.get("custom_field_values") is not None:
        payload["custom_field_values"] = item.get("custom_field_values")
    tag_slugs_raw = item.get("tag_slugs")
    if isinstance(tag_slugs_raw, list):
        tag_ids: list[str] = []
        for raw_slug in tag_slugs_raw:
            slug = must_str(raw_slug)
            if not slug:
                continue
            tag_id = must_str(tag_ids_by_slug.get(slug))
            if tag_id:
                tag_ids.append(tag_id)
        if tag_ids:
            payload["tag_ids"] = list(dict.fromkeys(tag_ids))

    existing = find_task_by_seed_key(existing_tasks, seed_key=normalized_key)
    if existing and existing.get("id"):
        task_id = must_str(existing.get("id"))
        request_json("PATCH", f"/boards/{board_id}/tasks/{task_id}", payload=payload)
        action = "updated"
    else:
        _, created = request_json("POST", f"/boards/{board_id}/tasks", payload=payload)
        task_id = must_str(created.get("id"))
        action = "created"
    if not task_id:
        raise SeedError(f"starter task upsert failed for key={seed_key}")
    return normalized_key, task_id, action


def apply_task_dependencies(
    *,
    board_id: str,
    dependency_specs: list[tuple[str, list[str]]],
    task_id_by_seed_key: dict[str, str],
) -> None:
    for task_seed_key, depends_on_keys in dependency_specs:
        task_id = must_str(task_id_by_seed_key.get(task_seed_key))
        if not task_id:
            continue
        depends_on_ids: list[str] = []
        for dep_key in depends_on_keys:
            dep_id = must_str(task_id_by_seed_key.get(slugify(dep_key, "task")))
            if dep_id:
                depends_on_ids.append(dep_id)
        payload = {"depends_on_task_ids": list(dict.fromkeys(depends_on_ids))}
        request_json("PATCH", f"/boards/{board_id}/tasks/{task_id}", payload=payload)


def default_single_board_config() -> dict[str, object]:
    return {
        "name": env("MC_BOARD_NAME", "Main Board"),
        "slug": env("MC_BOARD_SLUG", "main-board"),
        "description": env("MC_BOARD_DESCRIPTION", "Primary board for OpenClaw automation."),
        "perspective": env(
            "MC_BOARD_PERSPECTIVE",
            "Pragmatic execution: prioritize outcomes, clear ownership, and fast feedback loops.",
        ),
        "board_type": env("MC_BOARD_TYPE", "goal"),
        "objective": env("MC_BOARD_OBJECTIVE", ""),
        "goal_confirmed": env("MC_BOARD_GOAL_CONFIRMED", "false"),
        "goal_source": env("MC_BOARD_GOAL_SOURCE", ""),
        "target_date": env("MC_BOARD_TARGET_DATE", ""),
        "board_group_id": env("MC_BOARD_GROUP_ID", ""),
        "max_agents": env("MC_BOARD_MAX_AGENTS", "1"),
        "success_metrics": env("MC_BOARD_SUCCESS_METRICS_JSON", ""),
    }


def seed_single_board(
    *,
    board_config: dict[str, object],
    boards: list[dict[str, object]],
    gateway_id: str,
    summary: SeedSummary,
) -> None:
    payload = build_single_board_payload(config=board_config, gateway_id=gateway_id)
    existing = find_by_slug_or_name(
        boards,
        slug=must_str(payload.get("slug")),
        name=must_str(payload.get("name")),
    )
    if existing and existing.get("id"):
        board_id = must_str(existing.get("id"))
        _, result = request_json("PATCH", f"/boards/{board_id}", payload=payload)
        action = "updated"
    else:
        _, result = request_json("POST", "/boards", payload=payload)
        action = "created"
    board_id = must_str(result.get("id"))
    board_name = must_str(result.get("name"), must_str(payload.get("name")))
    board_slug = must_str(result.get("slug"), must_str(payload.get("slug")))
    if not board_id:
        raise SeedError("single board seed returned empty board id")
    summary.boards.append(
        {"id": board_id, "name": board_name, "slug": board_slug, "action": action},
    )


def seed_pack(
    *,
    pack: dict[str, object],
    boards_cache: list[dict[str, object]],
    gateway_id: str,
    summary: SeedSummary,
) -> None:
    version = parse_int(pack.get("version"), 1)
    if version != 1:
        raise SeedError(f"unsupported board pack version={version}; expected version=1")

    groups_cache = fetch_all("/board-groups")
    groups_cfg = pack.get("groups")
    group_ids_by_slug: dict[str, str] = {}
    if isinstance(groups_cfg, list):
        for raw in groups_cfg:
            if not isinstance(raw, dict):
                continue
            group_id, action = upsert_group(item=raw, groups=groups_cache)
            group_slug = must_str(raw.get("slug")) or slugify(raw.get("name"), "group")
            group_ids_by_slug[group_slug] = group_id
            summary.groups.append(
                {"id": group_id, "slug": group_slug, "name": must_str(raw.get("name")), "action": action},
            )

    boards_cfg = pack.get("boards")
    if not isinstance(boards_cfg, list) or not boards_cfg:
        raise SeedError("board pack requires boards[]")

    board_ids_by_slug: dict[str, str] = {}
    for raw in boards_cfg:
        if not isinstance(raw, dict):
            continue
        board_info, action = upsert_board(
            item=raw,
            boards=boards_cache,
            default_gateway_id=gateway_id,
            group_ids_by_slug=group_ids_by_slug,
        )
        board_slug = must_str(board_info.get("slug"))
        board_ids_by_slug[board_slug] = must_str(board_info.get("id"))
        summary.boards.append(
            {
                "id": must_str(board_info.get("id")),
                "slug": board_slug,
                "name": must_str(board_info.get("name")),
                "action": action,
            },
        )

    tags_cache = fetch_all("/tags")
    tag_ids_by_slug: dict[str, str] = {must_str(item.get("slug")): must_str(item.get("id")) for item in tags_cache}
    tags_cfg = pack.get("tags")
    if isinstance(tags_cfg, list):
        for raw in tags_cfg:
            if not isinstance(raw, dict):
                continue
            tag_id, tag_slug, action = upsert_tag(item=raw, tags=tags_cache)
            tag_ids_by_slug[tag_slug] = tag_id
            summary.tags.append({"id": tag_id, "slug": tag_slug, "name": must_str(raw.get("name")), "action": action})

    fields_cache_payload = request_json("GET", "/organizations/me/custom-fields")[1]
    fields_cache = fields_cache_payload if isinstance(fields_cache_payload, list) else []
    fields_cfg = pack.get("custom_fields")
    if isinstance(fields_cfg, list):
        for raw in fields_cfg:
            if not isinstance(raw, dict):
                continue
            field_key, action = upsert_custom_field(
                item=raw,
                existing_fields=[item for item in fields_cache if isinstance(item, dict)],
                board_ids_by_slug=board_ids_by_slug,
            )
            summary.custom_fields.append({"field_key": field_key, "action": action})

    webhooks_cfg = pack.get("webhooks")
    if isinstance(webhooks_cfg, list):
        for raw in webhooks_cfg:
            if not isinstance(raw, dict):
                continue
            board_slug = must_str(raw.get("board_slug"))
            board_id = must_str(board_ids_by_slug.get(board_slug))
            if not board_id:
                raise SeedError(f"webhook references unknown board_slug={board_slug}")
            existing_webhooks = fetch_all(f"/boards/{board_id}/webhooks")
            seed_key, webhook_id, endpoint_url, action = upsert_webhook(
                item=raw,
                board_id=board_id,
                webhooks=existing_webhooks,
            )
            summary.webhooks.append(
                {
                    "key": seed_key,
                    "board_slug": board_slug,
                    "id": webhook_id,
                    "endpoint_url": endpoint_url,
                    "action": action,
                },
            )

    starter_memory_cfg = pack.get("starter_memory")
    if isinstance(starter_memory_cfg, list):
        for raw in starter_memory_cfg:
            if not isinstance(raw, dict):
                continue
            board_slug = must_str(raw.get("board_slug"))
            board_id = must_str(board_ids_by_slug.get(board_slug))
            if not board_id:
                raise SeedError(f"starter_memory references unknown board_slug={board_slug}")
            existing_memory = fetch_all(f"/boards/{board_id}/memory", query={"is_chat": "false"})
            existing_seed_keys = list_seeded_board_memory_keys(existing_memory)
            seed_key, action = upsert_board_memory(
                item=raw,
                board_id=board_id,
                seeded_keys=existing_seed_keys,
            )
            summary.starter_memory.append({"key": seed_key, "board_slug": board_slug, "action": action})

    group_memory_cfg = pack.get("group_memory")
    if isinstance(group_memory_cfg, list):
        for raw in group_memory_cfg:
            if not isinstance(raw, dict):
                continue
            group_slug = must_str(raw.get("group_slug"))
            group_id = must_str(group_ids_by_slug.get(group_slug))
            if not group_id:
                raise SeedError(f"group_memory references unknown group_slug={group_slug}")
            existing = fetch_all(f"/board-groups/{group_id}/memory", query={"is_chat": "false"})
            existing_seed_keys = list_seeded_group_memory_keys(existing)
            seed_key, action = upsert_group_memory(
                item=raw,
                group_id=group_id,
                seeded_keys=existing_seed_keys,
            )
            summary.group_memory.append({"key": seed_key, "group_slug": group_slug, "action": action})

    tasks_cfg = pack.get("starter_tasks")
    if isinstance(tasks_cfg, list):
        tasks_by_board_slug: dict[str, list[dict[str, object]]] = {}
        for raw in tasks_cfg:
            if not isinstance(raw, dict):
                continue
            board_slug = must_str(raw.get("board_slug"))
            if board_slug:
                tasks_by_board_slug.setdefault(board_slug, []).append(raw)
        for board_slug, items in tasks_by_board_slug.items():
            board_id = must_str(board_ids_by_slug.get(board_slug))
            if not board_id:
                raise SeedError(f"starter_tasks references unknown board_slug={board_slug}")
            existing_tasks = fetch_all(f"/boards/{board_id}/tasks")
            task_id_by_seed_key: dict[str, str] = {}
            dependency_specs: list[tuple[str, list[str]]] = []
            for raw in items:
                seed_key, task_id, action = upsert_board_task(
                    item=raw,
                    board_id=board_id,
                    existing_tasks=existing_tasks,
                    tag_ids_by_slug=tag_ids_by_slug,
                )
                task_id_by_seed_key[seed_key] = task_id
                depends_on_keys = raw.get("depends_on_keys")
                if isinstance(depends_on_keys, list) and depends_on_keys:
                    dependency_specs.append((seed_key, [must_str(value) for value in depends_on_keys if must_str(value)]))
                summary.starter_tasks.append(
                    {
                        "key": seed_key,
                        "board_slug": board_slug,
                        "id": task_id,
                        "action": action,
                    },
                )
            apply_task_dependencies(
                board_id=board_id,
                dependency_specs=dependency_specs,
                task_id_by_seed_key=task_id_by_seed_key,
            )


def print_summary(summary: SeedSummary) -> None:
    first = summary.boards[0] if summary.boards else {}
    action = must_str(first.get("action"))
    board_id = must_str(first.get("id"))
    board_name = must_str(first.get("name"))
    board_slug = must_str(first.get("slug"))

    print(f"MISSION_CONTROL_BOARD_ACTION={action}")
    print(f"MISSION_CONTROL_BOARD_ID={board_id}")
    print(f"MISSION_CONTROL_BOARD_NAME={board_name}")
    print(f"MISSION_CONTROL_BOARD_SLUG={board_slug}")
    payload = json.dumps(summary.as_dict(), ensure_ascii=True)
    b64 = base64.b64encode(payload.encode("utf-8")).decode("utf-8")
    print(f"MISSION_CONTROL_SEED_SUMMARY_B64={b64}")


def main() -> int:
    token = env("MC_TOKEN")
    if not token:
        raise SeedError("mission control auth token is empty")
    headers["Authorization"] = f"Bearer {token}"

    board_config = decode_json_b64("MC_BOARD_CONFIG_B64")
    board_pack_config = decode_json_b64("MC_BOARD_PACK_CONFIG_B64")
    seed_board = parse_bool(env("MC_SEED_BOARD", "true"), True)
    seed_pack_enabled = parse_bool(env("MC_SEED_BOARD_PACK", "false"), False)

    request_json("POST", "/auth/bootstrap")
    gateways = fetch_all("/gateways")
    gateway_id = resolve_gateway_id(
        gateways,
        gateway_id_hint=env("MC_GATEWAY_ID"),
        gateway_name_hint=env("MC_GATEWAY_NAME"),
        gateway_url_hint=env("MC_GATEWAY_URL"),
    )
    boards_cache = fetch_all("/boards")

    summary = SeedSummary(
        mode="none",
        groups=[],
        boards=[],
        tags=[],
        custom_fields=[],
        webhooks=[],
        starter_memory=[],
        starter_tasks=[],
        group_memory=[],
    )

    should_seed_pack = seed_pack_enabled or bool(board_pack_config)
    if should_seed_pack and board_pack_config:
        summary.mode = "pack"
        seed_pack(
            pack=board_pack_config,
            boards_cache=boards_cache,
            gateway_id=gateway_id,
            summary=summary,
        )
    elif seed_board:
        summary.mode = "single"
        merged_single = default_single_board_config()
        merged_single.update({k: v for k, v in board_config.items() if v is not None})
        seed_single_board(
            board_config=merged_single,
            boards=boards_cache,
            gateway_id=gateway_id,
            summary=summary,
        )
    else:
        summary.mode = "skipped"

    print_summary(summary)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except SeedError as exc:
        raise SystemExit(str(exc))
