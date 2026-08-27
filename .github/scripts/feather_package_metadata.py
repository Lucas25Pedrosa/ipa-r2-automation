import asyncio
import hashlib
import json
import os
import re
from pathlib import Path
from urllib.parse import parse_qsl, parse_qs, urlencode, urlsplit, urlunsplit

from telethon import TelegramClient
from telethon.sessions import StringSession


PACKAGE_HOST = "feather.invalid"
PACKAGE_PATH = "/package"
PACKAGE_QUERY_KEYS = {
    "packageRevision",
    "featherRevision",
    "pkgRevision",
    "tweak",
    "tweakName",
    "tweakVersion",
    "packageLabel",
}


def set_output(name, value):
    output_path = os.environ.get("GITHUB_OUTPUT", "").strip()
    if not output_path:
        return

    with Path(output_path).open("a", encoding="utf-8") as handle:
        handle.write(f"{name}={value}\n")


def normalize_version(value):
    parts = str(value or "").strip().split(".")
    while len(parts) > 1 and parts[-1] == "0":
        parts.pop()
    return ".".join(parts)


def parse_package_url(url):
    try:
        parsed = urlsplit(str(url))
    except Exception:
        return None

    if parsed.scheme.lower() != "https":
        return None
    if (parsed.hostname or "").lower() != PACKAGE_HOST:
        return None
    if parsed.path != PACKAGE_PATH:
        return None

    values = parse_qs(parsed.query, keep_blank_values=False)

    def first(key):
        current = values.get(key) or []
        return str(current[-1]).strip() if current else ""

    metadata = {
        "schema": first("schema"),
        "bundle": first("bundle"),
        "appVersion": first("appVersion"),
        "packageName": first("packageName"),
        "packageVersion": first("packageVersion"),
        "packageRevision": first("packageRevision"),
        "packageLabel": first("packageLabel"),
        "fileSize": first("fileSize"),
    }

    required = (
        metadata["bundle"],
        metadata["appVersion"],
        metadata["packageName"],
        metadata["packageVersion"],
        metadata["packageRevision"],
    )

    return metadata if all(required) else None


def fallback_from_caption(message):
    text = str(getattr(message, "message", "") or "")
    if not text:
        return None

    bundle_match = re.search(
        r"Bundle ID:\s*([A-Za-z0-9._-]+)",
        text,
        flags=re.IGNORECASE,
    )
    version_match = re.search(
        r"Versão do app:\s*([^\n]+)",
        text,
        flags=re.IGNORECASE,
    )

    if not bundle_match or not version_match:
        return None

    bundle = bundle_match.group(1).strip()
    app_version = version_match.group(1).strip()

    lines = [line.strip() for line in text.splitlines()]
    version_line_index = None
    for index, line in enumerate(lines):
        if re.search(r"Versão do app:", line, flags=re.IGNORECASE):
            version_line_index = index
            break

    if version_line_index is None:
        return None

    tweak_entries = []
    for line in lines[version_line_index + 1 :]:
        if not line:
            continue
        if line.casefold() in {"aplicado", "não aplicado", "nao aplicado"}:
            continue
        if line.casefold().startswith("a estrutura desta versão"):
            continue
        if line.casefold().startswith("análise manual"):
            continue

        match = re.match(
            r"^(.+?)\s+([0-9][0-9A-Za-z._+\-]*)$",
            line,
        )
        if match:
            tweak_entries.append(
                {
                    "name": match.group(1).strip(),
                    "version": match.group(2).strip(),
                }
            )

    if not tweak_entries:
        return None

    canonical = json.dumps(
        tweak_entries,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    )
    revision = hashlib.sha256(canonical.encode("utf-8")).hexdigest()
    first = tweak_entries[0]

    file_size = ""
    try:
        file_size = str(int(message.file.size or 0))
    except Exception:
        pass

    return {
        "schema": "caption-fallback",
        "bundle": bundle,
        "appVersion": app_version,
        "packageName": first["name"],
        "packageVersion": first["version"],
        "packageRevision": revision,
        "packageLabel": f"{first['name']} {first['version']}",
        "fileSize": file_size,
    }


def metadata_from_message(message):
    for entity in getattr(message, "entities", None) or []:
        url = getattr(entity, "url", None)
        if not url:
            continue
        metadata = parse_package_url(url)
        if metadata:
            return metadata

    return fallback_from_caption(message)


def matches_target(metadata, message, bundle_id, app_version):
    if not metadata:
        return False

    if metadata["bundle"].casefold() != bundle_id.casefold():
        return False

    if normalize_version(metadata["appVersion"]) != normalize_version(app_version):
        return False

    expected_size = str(metadata.get("fileSize") or "").strip()
    if expected_size:
        try:
            message_size = int(message.file.size or 0)
            if message_size and message_size != int(expected_size):
                return False
        except Exception:
            return False

    return True


async def find_package_metadata(bundle_id, app_version):
    api_id = os.environ.get("TELEGRAM_API_ID", "").strip()
    api_hash = os.environ.get("TELEGRAM_API_HASH", "").strip()
    session = os.environ.get("TELEGRAM_SESSION", "").strip()

    if not api_id or not api_hash or not session:
        print("⚠️ Feather package metadata: credenciais do Telegram ausentes.")
        return None

    client = TelegramClient(
        StringSession(session),
        int(api_id),
        api_hash,
    )

    await client.connect()
    try:
        if not await client.is_user_authorized():
            print("⚠️ Feather package metadata: sessão do Telegram não autorizada.")
            return None

        channel_name = os.environ.get(
            "TELEGRAM_STORAGE_CHANNEL_NAME",
            "IPA Storage",
        ).strip() or "IPA Storage"

        channel = None
        async for dialog in client.iter_dialogs():
            if dialog.name == channel_name:
                channel = dialog.entity
                break

        if channel is None:
            print(
                "⚠️ Feather package metadata: canal "
                f"{channel_name!r} não encontrado."
            )
            return None

        async for message in client.iter_messages(channel, limit=100):
            if not getattr(message, "file", None):
                continue

            filename = str(message.file.name or "")
            if not filename.lower().endswith(".ipa"):
                continue

            metadata = metadata_from_message(message)
            if matches_target(metadata, message, bundle_id, app_version):
                print(
                    "🪶 Metadados do Injector encontrados: "
                    f"{metadata['packageLabel']} | "
                    f"rev {metadata['packageRevision'][:12]}"
                )
                return metadata

        print(
            "ℹ️ Nenhum metadado de pacote do Injector encontrado para "
            f"{bundle_id} {app_version}."
        )
        return None
    finally:
        await client.disconnect()


def with_package_query(url, metadata):
    parsed = urlsplit(str(url))
    query = [
        (key, value)
        for key, value in parse_qsl(parsed.query, keep_blank_values=True)
        if key not in PACKAGE_QUERY_KEYS
    ]

    query.extend(
        [
            ("packageRevision", metadata["packageRevision"]),
            ("tweak", metadata["packageName"]),
            ("tweakVersion", metadata["packageVersion"]),
            ("packageLabel", metadata["packageLabel"]),
        ]
    )

    return urlunsplit(
        (
            parsed.scheme,
            parsed.netloc,
            parsed.path,
            urlencode(query),
            parsed.fragment,
        )
    )


def update_source(metadata, bundle_id, app_version):
    repo_dir = Path(os.environ.get("PUBLIC_REPO_DIR") or os.getcwd()).resolve()
    source_path = repo_dir / "Feather" / "feather.json"

    if not source_path.is_file():
        print(f"⚠️ Feather package metadata: {source_path} não encontrado.")
        return False

    source = json.loads(source_path.read_text(encoding="utf-8"))
    apps = source.get("apps")
    if not isinstance(apps, list):
        print("⚠️ Feather package metadata: campo apps inválido.")
        return False

    target = None
    for app in apps:
        if not isinstance(app, dict):
            continue
        current_bundle = str(app.get("bundleIdentifier") or "").strip()
        if current_bundle.casefold() == bundle_id.casefold():
            target = app
            break

    if target is None:
        print(
            "⚠️ Feather package metadata: app não encontrado na source: "
            f"{bundle_id}."
        )
        return False

    versions = target.get("versions")
    target_version = None
    if isinstance(versions, list):
        for item in versions:
            if not isinstance(item, dict):
                continue
            if normalize_version(item.get("version")) == normalize_version(app_version):
                target_version = item
                break

    if target_version is None and isinstance(versions, list) and versions:
        first = versions[0]
        if isinstance(first, dict):
            target_version = first

    source_size = 0
    if isinstance(target_version, dict):
        try:
            source_size = int(target_version.get("size") or 0)
        except Exception:
            source_size = 0

    metadata_size = 0
    try:
        metadata_size = int(metadata.get("fileSize") or 0)
    except Exception:
        metadata_size = 0

    if source_size and metadata_size and source_size != metadata_size:
        print(
            "⚠️ Feather package metadata: tamanho do IPA diverge; "
            "metadado ignorado por segurança."
        )
        return False

    changed = False

    if isinstance(target_version, dict):
        current = str(target_version.get("downloadURL") or "").strip()
        if current:
            updated = with_package_query(current, metadata)
            if updated != current:
                target_version["downloadURL"] = updated
                changed = True

    current_top = str(target.get("downloadURL") or "").strip()
    if current_top:
        updated_top = with_package_query(current_top, metadata)
        if updated_top != current_top:
            target["downloadURL"] = updated_top
            changed = True

    if changed:
        source_path.write_text(
            json.dumps(source, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )
        print(
            "✅ Feather package metadata aplicado à source: "
            f"{metadata['packageLabel']}"
        )
    else:
        print("ℹ️ Feather package metadata já estava atualizado.")

    return changed


def main():
    set_output("changed", "false")

    bundle_id = os.environ.get("BUNDLE_ID", "").strip()
    app_version = os.environ.get("IPA_VERSION", "").strip()

    if not bundle_id or not app_version:
        print("ℹ️ Sem Bundle ID/versão; etapa de pacote ignorada.")
        return

    try:
        metadata = asyncio.run(
            find_package_metadata(bundle_id, app_version)
        )
    except Exception as exc:
        print(
            "⚠️ Feather package metadata: consulta ao Telegram falhou; "
            f"source normal será preservada. Detalhe: {exc}"
        )
        return

    if not metadata:
        return

    try:
        changed = update_source(metadata, bundle_id, app_version)
    except Exception as exc:
        print(
            "⚠️ Feather package metadata: pós-processamento falhou; "
            f"source normal será preservada. Detalhe: {exc}"
        )
        return

    set_output("changed", "true" if changed else "false")


if __name__ == "__main__":
    main()
