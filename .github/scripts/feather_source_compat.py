import importlib.util
import os
from pathlib import Path


def load_base_module():
    repo_dir = Path(os.environ.get("PUBLIC_REPO_DIR") or os.getcwd()).resolve()
    module_path = repo_dir / "private-core" / "scripts" / "feather_source.py"

    if not module_path.is_file():
        raise RuntimeError(f"Core do Feather não encontrado em {module_path}.")

    spec = importlib.util.spec_from_file_location("feather_source_base", module_path)
    if spec is None or spec.loader is None:
        raise RuntimeError("Não foi possível carregar feather_source.py.")

    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


base = load_base_module()
_original_build_feather_app = base.build_feather_app


def version_major_minor(version):
    parts = str(version or "").strip().split(".")

    if len(parts) < 2:
        return None

    try:
        return int(parts[0]), int(parts[1])
    except (TypeError, ValueError):
        return None


def same_release_family(left, right):
    left_family = version_major_minor(left)
    right_family = version_major_minor(right)
    return bool(left_family and right_family and left_family == right_family)


def existing_version_map(existing_app):
    result = {}

    if not isinstance(existing_app, dict):
        return result

    versions = existing_app.get("versions", [])
    if not isinstance(versions, list):
        return result

    for entry in versions:
        if not isinstance(entry, dict):
            continue

        ipa_version = str(entry.get("ipaVersion") or "").strip()
        public_version = str(entry.get("version") or "").strip()

        for candidate in (ipa_version, public_version):
            if candidate:
                result.setdefault(base.normalize_version(candidate), entry)

    return result


def release_metadata_for_version(
    app_store_id,
    app_name,
    version,
    store,
    history,
    existing_version,
):
    history_entry = base.history_version_entry(
        history,
        app_store_id,
        version,
    )

    store_version = ""
    if isinstance(store, dict):
        store_version = str(store.get("version") or "").strip()

    store_history_entry = (
        base.history_version_entry(history, app_store_id, store_version)
        if store_version
        else {}
    )

    is_store_current = bool(
        store_version
        and base.normalize_version(store_version) == base.normalize_version(version)
    )
    is_store_family = bool(
        store_version
        and same_release_family(store_version, version)
    )

    if is_store_current or is_store_family:
        release_date = str(
            store.get("currentVersionReleaseDate")
            or store_history_entry.get("release_date")
            or history_entry.get("release_date")
            or existing_version.get("date")
            or ""
        ).strip()

        release_notes_store = store.get("releaseNotes")

        if release_notes_store:
            release_notes = base.processar_texto_apple(
                release_notes_store,
                f"novidades de {app_name} {store_version or version}",
            )
        else:
            release_notes = str(
                store_history_entry.get("release_notes")
                or history_entry.get("release_notes")
                or existing_version.get("localizedDescription")
                or "Novidades não disponíveis."
            ).strip()

        metadata_source = "apple" if is_store_current else "apple-family"
        return release_date, release_notes, metadata_source

    release_date = str(
        history_entry.get("release_date")
        or existing_version.get("date")
        or ""
    ).strip()

    release_notes = str(
        history_entry.get("release_notes")
        or existing_version.get("localizedDescription")
        or "Novidades não disponíveis."
    ).strip()

    return release_date, release_notes, "history"


def build_feather_app(
    app_store_id,
    drive_entry,
    history,
    public_base,
    existing_app=None,
    store=None,
):
    result = _original_build_feather_app(
        app_store_id=app_store_id,
        drive_entry=drive_entry,
        history=history,
        public_base=public_base,
        existing_app=existing_app,
        store=store,
    )

    current_ipa_version = str(
        drive_entry.get("current_version")
        if isinstance(drive_entry, dict)
        else ""
    ).strip()
    store_version = str(
        store.get("version")
        if isinstance(store, dict)
        else ""
    ).strip()

    versions = result.get("versions", [])
    if not isinstance(versions, list):
        raise RuntimeError("Campo versions inválido após montar o Feather.")

    current_entry = None

    for entry in versions:
        if not isinstance(entry, dict):
            continue

        internal_version = str(
            entry.get("ipaVersion") or entry.get("version") or ""
        ).strip()

        if internal_version:
            entry["ipaVersion"] = internal_version

        if entry.get("date") == "":
            entry.pop("date", None)

        if (
            internal_version
            and current_ipa_version
            and base.normalize_version(internal_version)
            == base.normalize_version(current_ipa_version)
        ):
            current_entry = entry

    if current_entry is None:
        raise RuntimeError(
            f"Não foi possível localizar o IPA atual {current_ipa_version} "
            "após montar o Feather."
        )

    if store_version:
        current_entry["version"] = store_version

    result["ipaVersion"] = current_ipa_version
    result["version"] = str(current_entry.get("version") or current_ipa_version)

    current_date = str(current_entry.get("date") or "").strip()
    if current_date:
        result["versionDate"] = current_date
    else:
        result.pop("versionDate", None)

    if store_version and base.normalize_version(store_version) != base.normalize_version(current_ipa_version):
        print(
            "ℹ️ Versão pública App Store "
            f"{store_version}; versão interna do IPA {current_ipa_version}."
        )

    return result


base.existing_version_map = existing_version_map
base.release_metadata_for_version = release_metadata_for_version
base.build_feather_app = build_feather_app


if __name__ == "__main__":
    base.main()
