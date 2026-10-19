import importlib.util
import json
import os
from pathlib import Path


def load_base_module():
    module_path = Path(__file__).with_name("feather_package_metadata.py")
    spec = importlib.util.spec_from_file_location(
        "feather_package_metadata_base",
        module_path,
    )
    if spec is None or spec.loader is None:
        raise RuntimeError("Não foi possível carregar feather_package_metadata.py.")

    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


base = load_base_module()


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

            source_ipa_version = str(
                item.get("ipaVersion") or item.get("version") or ""
            ).strip()

            if (
                base.normalize_version(source_ipa_version)
                == base.normalize_version(app_version)
            ):
                target_version = item
                break

    if target_version is None:
        print(
            "⚠️ Feather package metadata: versão interna exata não encontrada "
            f"na source: {bundle_id} {app_version}. Nenhuma outra versão será alterada."
        )
        return False

    source_size = 0
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

    current = str(target_version.get("downloadURL") or "").strip()
    if current:
        updated = base.with_package_query(current, metadata)
        if updated != current:
            target_version["downloadURL"] = updated
            changed = True

    current_app_version = str(
        target.get("ipaVersion") or target.get("version") or ""
    ).strip()

    if (
        base.normalize_version(current_app_version)
        == base.normalize_version(app_version)
    ):
        current_top = str(target.get("downloadURL") or "").strip()

        if current_top:
            updated_top = base.with_package_query(current_top, metadata)

            if updated_top != current_top:
                target["downloadURL"] = updated_top
                changed = True
    else:
        print(
            "ℹ️ Feather package metadata: versão histórica atualizada sem "
            "alterar o downloadURL principal do app."
        )

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


base.update_source = update_source


if __name__ == "__main__":
    base.main()
