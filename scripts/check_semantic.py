#!/usr/bin/env python3
"""Проверяет семантический слой против базы: витрина из source существует, колонки из
dimensions/measures в ней есть, типы мер — из разрешённых. Код возврата 1 при любом расхождении.

YAML здесь плоский и одного формата, поэтому разбирается регулярками — без PyYAML.
"""
import os
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MEASURE_TYPES = {"sum", "avg", "count"}
PG = os.environ.get("PG", "crs-pg")


def view_columns(view):
    schema, name = view.split(".", 1)
    out = subprocess.run(
        ["docker", "exec", "-i", PG, "psql", "-U", "postgres", "-d", "risk", "-qAt", "-c",
         "SELECT column_name FROM information_schema.columns "
         f"WHERE table_schema = '{schema}' AND table_name = '{name}'"],
        check=True, capture_output=True, text=True,
    ).stdout
    return set(out.split())


def main():
    errors = []
    files = sorted((ROOT / "semantic").glob("*.yaml"))
    for path in files:
        text = path.read_text(encoding="utf-8")
        source = re.search(r"^source:\s*(\S+)", text, re.M)
        if not source:
            errors.append(f"{path.name}: нет source")
            continue
        columns = view_columns(source.group(1))
        if not columns:
            errors.append(f"{path.name}: витрины {source.group(1)} нет в базе")
            continue
        for col in re.findall(r"^\s+column:\s*(\S+)", text, re.M):
            if col not in columns:
                errors.append(f"{path.name}: колонки {col} нет в {source.group(1)}")
        measures = text.split("measures:", 1)[1] if "measures:" in text else ""
        for kind in re.findall(r"^\s+type:\s*(\S+)", measures, re.M):
            if kind not in MEASURE_TYPES:
                errors.append(f"{path.name}: тип меры {kind} не из {sorted(MEASURE_TYPES)}")
    if errors:
        print("FAIL:\n  " + "\n  ".join(errors), file=sys.stderr)
        sys.exit(1)
    print(f"check_semantic: OK — {len(files)} моделей, все колонки есть в витринах")


if __name__ == "__main__":
    main()
