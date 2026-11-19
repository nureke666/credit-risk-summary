#!/usr/bin/env bash
# Выгружает витрины reporting.* в JSON, который читают спеки дашборда (dashboard/data/).
set -euo pipefail
cd "$(dirname "$0")/.."

PG="${PG:-crs-pg}"
OUT=dashboard/data
mkdir -p "$OUT"

# dump <файл> <витрина> <порядок> [условие]
dump() {
    docker exec -i "$PG" psql -U postgres -d risk -v ON_ERROR_STOP=1 -qAt -c \
        "SELECT coalesce(json_agg(t ORDER BY $3), '[]') FROM (SELECT * FROM $2 ${4:-}) t" \
        > "$OUT/$1.json"
}

dump summary      reporting.v_risk_summary    "report_date"
dump by_segment   reporting.v_risk_by_segment "report_date, dimension, portfolio_kzt DESC"
dump top_groups   reporting.v_group_exposure  "report_date, exposure_rank" "WHERE exposure_rank <= 10"
dump data_quality reporting.v_data_quality    "report_date"

echo "export: $(ls "$OUT" | tr '\n' ' ')→ $OUT/"
