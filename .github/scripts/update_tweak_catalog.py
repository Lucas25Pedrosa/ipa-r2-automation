import json
import os
from pathlib import Path
from urllib.parse import parse_qs, urlsplit


def _set_output(name: str, value: str) -> None:
    output = os.environ.get("GITHUB_OUTPUT", "").strip()
    if not output:
        return
    with Path(output).open("a", encoding="utf-8") as handle:
        handle.write(f"{name}={value}\n")


def _package_metadata(url: str) -> dict | None:
    if not url:
        return None
    try:
        values = parse_qs(urlsplit(url).query, keep_blank_values=False)
    except Exception:
        return None

    def first(*keys: str) -> str:
        for key in keys:
            current = values.get(key) or []
            if current:
                value = str(current[-1]).strip()
                if value:
                    return value
        return ""

    name = first("tweak", "tweakName")
    version = first("tweakVersion")
    revision = first("packageRevision", "featherRevision", "pkgRevision")
    label = first("packageLabel")
    if not name or not version:
        return None
    return {
        "name": name,
        "version": version,
        "revision": revision,
        "label": label or f"{name} {version}",
    }


def _source_package(app: dict) -> dict | None:
    candidates: list[str] = []
    top = str(app.get("downloadURL") or "").strip()
    if top:
        candidates.append(top)
    versions = app.get("versions")
    if isinstance(versions, list):
        for item in versions:
            if isinstance(item, dict):
                value = str(item.get("downloadURL") or "").strip()
                if value:
                    candidates.append(value)
    for url in candidates:
        metadata = _package_metadata(url)
        if metadata:
            return metadata
    return None


def main() -> None:
    _set_output("changed", "false")
    repo = Path(os.environ.get("PUBLIC_REPO_DIR") or os.getcwd()).resolve()
    source_path = repo / "Feather" / "feather.json"
    catalog_path = repo / "Feather" / "tweaks.json"

    if not source_path.is_file():
        raise SystemExit(f"Feather source não encontrada: {source_path}")

    source = json.loads(source_path.read_text(encoding="utf-8"))
    apps = source.get("apps")
    if not isinstance(apps, list):
        raise SystemExit("Feather source inválida: apps precisa ser uma lista.")

    if catalog_path.is_file():
        catalog = json.loads(catalog_path.read_text(encoding="utf-8"))
    else:
        catalog = {"schemaVersion": 1, "apps": {}}

    if catalog.get("schemaVersion") != 1:
        raise SystemExit("tweaks.json usa schemaVersion não suportado.")

    catalog_apps = catalog.setdefault("apps", {})
    if not isinstance(catalog_apps, dict):
        raise SystemExit("tweaks.json inválido: apps precisa ser um objeto.")

    changed = False
    for app in apps:
        if not isinstance(app, dict):
            continue
        bundle = str(app.get("bundleIdentifier") or app.get("bundleID") or "").strip()
        if not bundle:
            continue
        package = _source_package(app)
        if not package:
            continue

        app_name = str(app.get("name") or app.get("localizedDescription") or bundle).strip() or bundle
        record = catalog_apps.get(bundle)
        if not isinstance(record, dict):
            record = {"name": app_name, "addons": []}
            catalog_apps[bundle] = record
            changed = True
        elif record.get("name") != app_name:
            record["name"] = app_name
            changed = True

        addons = record.setdefault("addons", [])
        if not isinstance(addons, list):
            addons = []
            record["addons"] = addons
            changed = True

        addon = next(
            (
                item
                for item in addons
                if isinstance(item, dict)
                and str(item.get("name") or "").casefold() == package["name"].casefold()
            ),
            None,
        )
        if addon is None:
            addon = {
                "name": package["name"],
                "currentVersion": package["version"],
                "knownVersions": [package["version"]],
            }
            addons.append(addon)
            changed = True

        known = addon.get("knownVersions")
        if not isinstance(known, list):
            known = []
        normalized_known = [str(value).strip() for value in known if str(value).strip()]
        old_current = str(addon.get("currentVersion") or "").strip()
        for value in (old_current, package["version"]):
            if value and value not in normalized_known:
                normalized_known.append(value)
        if addon.get("knownVersions") != normalized_known:
            addon["knownVersions"] = normalized_known
            changed = True

        if old_current != package["version"]:
            addon["currentVersion"] = package["version"]
            changed = True
        if package["revision"] and addon.get("currentRevision") != package["revision"]:
            addon["currentRevision"] = package["revision"]
            changed = True
        if addon.get("packageLabel") != package["label"]:
            addon["packageLabel"] = package["label"]
            changed = True

    if changed:
        catalog_path.write_text(
            json.dumps(catalog, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )
        print("✅ Catálogo público de tweaks atualizado.")
        _set_output("changed", "true")
    else:
        print("ℹ️ Catálogo público de tweaks já está atualizado.")


if __name__ == "__main__":
    main()
