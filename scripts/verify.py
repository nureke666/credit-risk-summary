#!/usr/bin/env python3
"""Пересчитывает риск-сводку из исходных CSV без SQL и сверяет с выгрузкой дашборда.

Вторая, независимая реализация определений из задания: расхождение хотя бы в одной цифре
между витринами (dashboard/data/*.json) и этим пересчётом — код возврата 1.
Только стандартная библиотека: запускается без venv и без базы.
"""
import csv
import json
import sys
from collections import Counter, defaultdict
from decimal import Decimal, getcontext
from pathlib import Path

getcontext().prec = 50
ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "data"
OUT = ROOT / "dashboard" / "data"

KZT_TOL = Decimal("0.01")     # суммы в тенге — до тиына
SHARE_TOL = Decimal("1e-12")  # доли — с запасом на округление деления numeric в Postgres
PP_TOL = Decimal("1e-9")      # изменения в п.п. и процентах


def read_csv(path):
    with open(path, newline="", encoding="utf-8-sig") as f:
        return list(csv.DictReader(f))


def load_loans():
    """Кредиты без полных дублей; на дату — одна строка на кредит, иначе стоп."""
    raw = read_csv(SRC / "portfolio.csv")
    unique = [dict(t) for t in {tuple(r.items()) for r in raw}]
    keys = Counter((r["report_date"], r["loan_id"]) for r in unique)
    conflicts = [k for k, n in keys.items() if n > 1]
    if conflicts:
        sys.exit(f"FAIL: у кредита несколько разных строк на одну дату: {conflicts[:5]}")
    raw_by_date = Counter(r["report_date"] for r in raw)
    unique_by_date = Counter(r["report_date"] for r in unique)
    return unique, {d: raw_by_date[d] - unique_by_date[d] for d in raw_by_date}


def load_rates():
    rates = {}
    for r in read_csv(SRC / "fx.csv"):
        key = (r["date"], r["currency"].strip().upper())
        if key in rates:
            sys.exit(f"FAIL: два курса на {key}")
        rates[key] = Decimal(r["rate_kzt"])
    return rates


def provision_rate(dpd, is_npl):
    if is_npl:
        return Decimal("0.50")
    if dpd > 30:
        return Decimal("0.10")
    return Decimal("0.01")


def dpd_bucket(dpd):
    if dpd == 0:
        return "без просрочки"
    if dpd <= 30:
        return "1–30 дней"
    if dpd <= 90:
        return "31–90 дней"
    return "более 90 дней"


def compute(loans, rates):
    """Метрики на каждую дату среза — по определениям из задания, без оглядки на SQL."""
    summary, segments, groups, written_off_by_date = {}, {}, {}, {}
    for date in sorted({r["report_date"] for r in loans}):
        m = defaultdict(Decimal)
        seg = defaultdict(lambda: defaultdict(Decimal))
        exposure = defaultdict(Decimal)
        written_off = 0
        for r in loans:
            if r["report_date"] != date:
                continue
            if int(r["written_off"]) == 1:
                written_off += 1
                continue
            cur = r["currency"].strip().upper()
            if cur != "KZT" and (date, cur) not in rates:
                sys.exit(f"FAIL: нет курса {cur} на {date}")
            amount = Decimal(r["principal_outstanding"]) * (Decimal(1) if cur == "KZT" else rates[(date, cur)])
            dpd = int(r["days_past_due"])
            is_npl = dpd > 90 or int(r["restructured"]) == 1
            row = {
                "portfolio_kzt": amount,
                "par30_kzt": amount if dpd > 30 else Decimal(0),
                "par90_kzt": amount if dpd > 90 else Decimal(0),
                "npl_kzt": amount if is_npl else Decimal(0),
                "provisions_kzt": amount * provision_rate(dpd, is_npl),
            }
            m["loans_count"] += 1
            for k, v in row.items():
                m[k] += v
                for dim, value in (("sector", r["sector"]), ("program", r["program"]), ("dpd_bucket", dpd_bucket(dpd))):
                    seg[(dim, value)][k] += v
            exposure[r["group_id"]] += amount

        top10 = sorted(exposure.values(), reverse=True)[:10]
        total = m["portfolio_kzt"]
        m["top10_kzt"] = sum(top10, Decimal(0))
        for k in ("par30", "par90", "npl", "top10"):
            m[f"{k}_share"] = m[f"{k}_kzt"] / total
        summary[date], segments[date], groups[date] = m, seg, top10
        written_off_by_date[date] = written_off

    dates = sorted(summary)
    for prev, cur in zip(dates, dates[1:]):
        p, c = summary[prev], summary[cur]
        c["portfolio_change_ratio"] = c["portfolio_kzt"] / p["portfolio_kzt"] - 1
        c["provisions_change_ratio"] = c["provisions_kzt"] / p["provisions_kzt"] - 1
        for k in ("par30", "par90", "npl", "top10"):
            c[f"{k}_change_pp"] = (c[f"{k}_share"] - p[f"{k}_share"]) * 100
    return summary, segments, groups, written_off_by_date


def tolerance(field):
    if field.endswith("_share"):
        return SHARE_TOL
    if field.endswith(("_pp", "_ratio")):
        return PP_TOL
    return KZT_TOL


def main():
    loans, duplicates = load_loans()
    expected, exp_segments, exp_groups, written_off = compute(loans, load_rates())

    def load(name):
        with open(OUT / f"{name}.json", encoding="utf-8") as f:
            return json.load(f, parse_float=Decimal)

    errors, checked = [], 0

    def same(where, field, exp, act):
        nonlocal checked
        checked += 1
        if act is None or abs(Decimal(exp) - Decimal(act)) > tolerance(field):
            errors.append(f"{where} {field}: пересчёт {exp}, витрина {act}")

    actual = {r["report_date"]: r for r in load("summary")}
    if set(actual) != set(expected):
        sys.exit(f"FAIL: даты срезов не совпадают: витрина {sorted(actual)}, пересчёт {sorted(expected)}")
    for date, exp in expected.items():
        for field, value in exp.items():
            same(date, field, value, actual[date].get(field))

    for r in load("by_segment"):
        exp = exp_segments[r["report_date"]].get((r["dimension"], r["segment"]))
        if exp is None:
            errors.append(f"{r['report_date']} {r['dimension']}={r['segment']}: сегмента нет в пересчёте")
            continue
        for field in ("portfolio_kzt", "par30_kzt", "par90_kzt", "npl_kzt", "provisions_kzt"):
            same(f"{r['report_date']} {r['segment']}", field, exp[field], r[field])
    seg_count = sum(len(s) for s in exp_segments.values())
    if len(load("by_segment")) != seg_count:
        errors.append(f"by_segment: строк {len(load('by_segment'))}, сегментов в пересчёте {seg_count}")

    top = defaultdict(list)
    for r in load("top_groups"):
        top[r["report_date"]].append(r["exposure_kzt"])
    for date, values in exp_groups.items():
        for i, (exp, act) in enumerate(zip(values, sorted(top[date], reverse=True)), 1):
            same(date, f"top{i}_exposure_kzt", exp, act)

    for r in load("data_quality"):
        same(r["report_date"], "duplicate_rows", duplicates[r["report_date"]], r["duplicate_rows"])
        same(r["report_date"], "written_off_loans", written_off[r["report_date"]], r["written_off_loans"])

    print_summary(expected, duplicates, written_off)
    if errors:
        print(f"\nFAIL: {len(errors)} расхождений из {checked} сверок:", file=sys.stderr)
        for e in errors[:30]:
            print("  " + e, file=sys.stderr)
        sys.exit(1)
    print(f"\nverify: OK — {checked} сверок, витрины и независимый пересчёт совпадают")


def print_summary(expected, duplicates, written_off):
    dates = sorted(expected)
    rows = [
        ("Кредитов в портфеле", lambda m: f"{m['loans_count']}"),
        ("Портфель, млрд ₸", lambda m: f"{m['portfolio_kzt'] / 10**9:,.1f}"),
        ("PAR30", lambda m: f"{m['par30_share'] * 100:.2f}%"),
        ("PAR90", lambda m: f"{m['par90_share'] * 100:.2f}%"),
        ("NPL", lambda m: f"{m['npl_share'] * 100:.2f}%"),
        ("Провизии, млрд ₸", lambda m: f"{m['provisions_kzt'] / 10**9:,.2f}"),
        ("Топ-10 групп", lambda m: f"{m['top10_share'] * 100:.2f}%"),
    ]
    extra = [("Дублей отброшено", duplicates), ("Списанных исключено", written_off)]
    print(f"{'':24}" + "".join(f"{d:>14}" for d in dates))
    for title, fmt in rows:
        cells = [fmt(expected[d]) for d in dates]
        print(f"{title:24}" + "".join(f"{c:>14}" for c in cells))
    for title, by_date in extra:
        cells = [str(by_date[d]) for d in dates]
        print(f"{title:24}" + "".join(f"{c:>14}" for c in cells))


if __name__ == "__main__":
    main()
