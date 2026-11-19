-- Инварианты данных и метрик. Любая непройденная проверка останавливает прогон (ON_ERROR_STOP).
-- Имя проверки — в check_name; на него ссылаются README и AGENTS.md.
CREATE OR REPLACE VIEW reporting.v_check_failures AS
SELECT check_name, failures
FROM (
    -- unique_loan_per_date: после схлопывания полных дублей кредит встречается на дату один раз.
    -- Иначе дубли расходятся в значениях, и выбрать «правильную» строку молча нельзя.
    SELECT 'unique_loan_per_date' AS check_name, count(*) AS failures
    FROM (
        SELECT 1 FROM reporting.v_loans_clean GROUP BY report_date, loan_id HAVING count(*) > 1
    ) x
    UNION ALL
    -- single_fx_rate_per_day: два курса на один день размножили бы кредиты в join.
    SELECT 'single_fx_rate_per_day', count(*)
    FROM (
        SELECT 1 FROM raw.fx GROUP BY date::date, upper(trim(currency)) HAVING count(*) > 1
    ) x
    UNION ALL
    -- fx_rate_on_report_date: у каждого валютного кредита есть курс ровно на дату среза.
    SELECT 'fx_rate_on_report_date', count(*)
    FROM reporting.v_loans_clean
    WHERE principal_kzt IS NULL
    UNION ALL
    -- segments_sum_to_total: каждый разрез (отрасль, программа, корзина) складывается в портфель.
    SELECT 'segments_sum_to_total', count(*)
    FROM (
        SELECT report_date, dimension, sum(portfolio_kzt) AS total
        FROM reporting.v_risk_by_segment
        GROUP BY report_date, dimension
    ) g
    JOIN reporting.v_risk_summary s USING (report_date)
    WHERE g.total <> s.portfolio_kzt
    UNION ALL
    -- metric_bounds: PAR90 ⊆ PAR30, PAR90 ⊆ NPL, провизии между 1% и 50% портфеля.
    SELECT 'metric_bounds', count(*)
    FROM reporting.v_risk_summary
    WHERE NOT (
        par90_kzt <= par30_kzt
        AND par90_kzt <= npl_kzt
        AND provisions_kzt BETWEEN portfolio_kzt * 0.01 AND portfolio_kzt * 0.50
        AND top10_share > 0 AND top10_share <= 1
    )
) c
WHERE failures > 0;

DO $$
DECLARE
    failed text;
BEGIN
    SELECT string_agg(check_name || ' (' || failures || ')', ', ') INTO failed
    FROM reporting.v_check_failures;
    IF failed IS NOT NULL THEN
        RAISE EXCEPTION 'проверки витрин не пройдены: %', failed;
    END IF;
END
$$;
