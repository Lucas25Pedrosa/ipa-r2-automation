#!/usr/bin/env python3

import json
import re
import sys
import urllib.parse
import urllib.request
from pathlib import Path

SOURCE_PATH = Path("Feather/feather.json")
ITUNES_LOOKUP = "https://itunes.apple.com/lookup"
USER_AGENT = "Mozilla/5.0 (compatible; Feather-Description-Guard/1.0)"


def normalize_spaces(text):
    return re.sub(r"\s+", " ", str(text or "")).strip()


def repeated_sentence_ratio(text):
    normalized = normalize_spaces(text)
    if len(normalized) < 120:
        return 0.0

    sentences = [
        normalize_spaces(part).casefold()
        for part in re.split(r"(?<=[.!?])\s+|[;\n]+", normalized)
        if len(normalize_spaces(part)) >= 12
    ]
    if len(sentences) < 4:
        return 0.0

    counts = {}
    for sentence in sentences:
        counts[sentence] = counts.get(sentence, 0) + 1

    repeated = sum(count for count in counts.values() if count > 1)
    return repeated / len(sentences)


def repeated_ngram_score(text, n=6):
    words = re.findall(r"[\wÀ-ÿ]+", normalize_spaces(text).casefold())
    if len(words) < n * 4:
        return 0

    counts = {}
    for index in range(len(words) - n + 1):
        gram = tuple(words[index : index + n])
        counts[gram] = counts.get(gram, 0) + 1

    return max(counts.values(), default=0)


def is_degenerate(text):
    normalized = normalize_spaces(text)
    if not normalized:
        return True

    if repeated_sentence_ratio(normalized) >= 0.45:
        return True

    if repeated_ngram_score(normalized) >= 5:
        return True

    return False


def lookup_store(bundle_id):
    query = urllib.parse.urlencode(
        {
            "bundleId": bundle_id,
            "country": "br",
        }
    )
    request = urllib.request.Request(
        f"{ITUNES_LOOKUP}?{query}",
        headers={"User-Agent": USER_AGENT},
    )

    with urllib.request.urlopen(request, timeout=30) as response:
        payload = json.load(response)

    results = payload.get("results") or []
    if not results:
        return None

    return results[0]


def repair_app(app):
    bundle_id = str(app.get("bundleIdentifier") or "").strip()
    app_name = str(app.get("name") or bundle_id or "app")
    description = str(app.get("localizedDescription") or "")

    if not bundle_id or not is_degenerate(description):
        return False

    print(f"⚠️ Descrição suspeita detectada: {app_name} ({bundle_id})")

    try:
        store = lookup_store(bundle_id)
    except Exception as exc:
        print(f"❌ Falha ao consultar App Store BR para {app_name}: {exc}")
        return False

    if not store:
        print(f"❌ App Store BR não retornou dados para {app_name}")
        return False

    store_description = str(store.get("description") or "").strip()

    if not store_description:
        print(f"❌ App Store BR sem descrição para {app_name}")
        return False

    if is_degenerate(store_description):
        print(f"❌ Descrição da App Store também parece inválida para {app_name}")
        return False

    app["localizedDescription"] = store_description
    print(f"✅ Descrição restaurada pela App Store BR: {app_name}")

    current_store_version = str(store.get("version") or "").strip()
    release_notes = str(store.get("releaseNotes") or "").strip()

    if current_store_version and release_notes and not is_degenerate(release_notes):
        for version in app.get("versions") or []:
            if not isinstance(version, dict):
                continue

            if str(version.get("version") or "").strip() != current_store_version:
                continue

            current_notes = str(version.get("localizedDescription") or "")
            if is_degenerate(current_notes):
                version["localizedDescription"] = release_notes
                print(
                    "✅ Notas da versão atual restauradas pela App Store BR: "
                    f"{app_name} {current_store_version}"
                )

    return True


def main():
    if not SOURCE_PATH.is_file():
        raise SystemExit(f"Source não encontrada: {SOURCE_PATH}")

    data = json.loads(SOURCE_PATH.read_text(encoding="utf-8"))
    apps = data.get("apps")

    if not isinstance(apps, list):
        raise SystemExit("Feather/feather.json não contém apps[] válido")

    changed = False

    for app in apps:
        if not isinstance(app, dict):
            continue

        if repair_app(app):
            changed = True

    if not changed:
        print("✅ Nenhuma descrição degenerada encontrada")
        return 0

    SOURCE_PATH.write_text(
        json.dumps(data, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    print("✅ Feather/feather.json corrigido")
    return 0


if __name__ == "__main__":
    sys.exit(main())
