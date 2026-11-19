-- Витрины риск-сводки. Определения метрик — из задания, толкования спорных мест — в README.

-- Очищенные кредиты: без полных дублей, с типами, с суммой в тенге по курсу на дату среза.
-- Списанные здесь остаются (с флагом) — их видно в v_data_quality; из портфеля их убирает v_portfolio.
CREATE OR REPLACE VIEW reporting.v_loans_clean AS
WITH dedup AS (
    SELECT DISTINCT
        p.report_date::date                     AS report_date,
        p.loan_id,
        p.borrower_id,
        p.group_id,
        p.sector,
        p.program,
        upper(trim(p.currency))                 AS currency,
        p.issue_date::date                      AS issue_date,
        p.maturity_date::date                   AS maturity_date,
        p.principal_outstanding::numeric(20, 2) AS principal_outstanding,
        p.days_past_due::int                    AS days_past_due,
        p.restructured::int = 1                 AS is_restructured,
        p.written_off::int = 1                  AS is_written_off
    FROM raw.portfolio p
),
fx AS (
    SELECT date::date AS rate_date, upper(trim(currency)) AS currency, rate_kzt::numeric AS rate_kzt
    FROM raw.fx
)
SELECT
    d.*,
    -- Курс строго на дату среза, без подстановки соседнего дня: нет курса — сумма NULL,
    -- и проверка fx_rate_on_report_date в 90_checks.sql останавливает прогон.
    CASE WHEN d.currency = 'KZT' THEN 1::numeric ELSE fx.rate_kzt END AS fx_rate,
    d.principal_outstanding
        * CASE WHEN d.currency = 'KZT' THEN 1::numeric ELSE fx.rate_kzt END AS principal_kzt
FROM dedup d
LEFT JOIN fx ON fx.rate_date = d.report_date AND fx.currency = d.currency;

-- Витрина портфеля: одна строка — кредит на дату среза, списанные исключены.
-- Флаги и суммы риска лежат колонками, чтобы семантический слой собирал их простым sum.
CREATE OR REPLACE VIEW reporting.v_portfolio AS
SELECT
    l.report_date,
    l.loan_id,
    l.borrower_id,
    l.group_id,
    l.sector,
    l.program,
    l.currency,
    l.issue_date,
    l.maturity_date,
    l.days_past_due,
    CASE
        WHEN l.days_past_due = 0  THEN 'без просрочки'
        WHEN l.days_past_due <= 30 THEN '1–30 дней'
        WHEN l.days_past_due <= 90 THEN '31–90 дней'
        ELSE 'более 90 дней'
    END                                                         AS dpd_bucket,
    l.is_restructured,
    l.days_past_due > 30                                        AS is_par30,
    l.days_past_due > 90                                        AS is_par90,
    r.is_npl,
    l.principal_outstanding,
    l.fx_rate,
    l.principal_kzt,
    CASE WHEN l.days_past_due > 30 THEN l.principal_kzt ELSE 0 END AS par30_kzt,
    CASE WHEN l.days_past_due > 90 THEN l.principal_kzt ELSE 0 END AS par90_kzt,
    CASE WHEN r.is_npl THEN l.principal_kzt ELSE 0 END             AS npl_kzt,
    r.provision_rate,
    l.principal_kzt * r.provision_rate                          AS provision_kzt
FROM reporting.v_loans_clean l
CROSS JOIN LATERAL (
    SELECT
        l.days_past_due > 90 OR l.is_restructured AS is_npl,
        -- NPL важнее корзины просрочки: реструктуризированный кредит без просрочки идёт под 50%.
        CASE
            WHEN l.days_past_due > 90 OR l.is_restructured THEN 0.50
            WHEN l.days_past_due > 30 THEN 0.10
            ELSE 0.01
        END::numeric AS provision_rate
) r
WHERE NOT l.is_written_off;

-- Экспозиция по группам связанных заёмщиков: группа, а не заёмщик — в группе бывает до пяти заёмщиков.
CREATE OR REPLACE VIEW reporting.v_group_exposure AS
WITH g AS (
    SELECT
        report_date,
        group_id,
        count(DISTINCT borrower_id) AS borrowers_count,
        count(*)                    AS loans_count,
        sum(principal_kzt)          AS exposure_kzt
    FROM reporting.v_portfolio
    GROUP BY report_date, group_id
)
SELECT
    g.*,
    g.exposure_kzt / sum(g.exposure_kzt) OVER (PARTITION BY g.report_date) AS portfolio_share,
    row_number() OVER (PARTITION BY g.report_date ORDER BY g.exposure_kzt DESC, g.group_id) AS exposure_rank
FROM g;

-- Риск-сводка: одна строка на дату среза и изменение к предыдущему срезу.
-- *_change_ratio — относительное изменение (0.012 = +1,2%), *_change_pp — в процентных пунктах.
CREATE OR REPLACE VIEW reporting.v_risk_summary AS
WITH m AS (
    SELECT
        report_date,
        count(*)                    AS loans_count,
        count(DISTINCT borrower_id) AS borrowers_count,
        count(DISTINCT group_id)    AS groups_count,
        sum(principal_kzt)          AS portfolio_kzt,
        sum(par30_kzt)              AS par30_kzt,
        sum(par90_kzt)              AS par90_kzt,
        sum(npl_kzt)                AS npl_kzt,
        sum(provision_kzt)          AS provisions_kzt
    FROM reporting.v_portfolio
    GROUP BY report_date
),
top10 AS (
    SELECT report_date, sum(exposure_kzt) AS top10_kzt
    FROM reporting.v_group_exposure
    WHERE exposure_rank <= 10
    GROUP BY report_date
),
s AS (
    SELECT
        m.*,
        t.top10_kzt,
        m.par30_kzt / m.portfolio_kzt AS par30_share,
        m.par90_kzt / m.portfolio_kzt AS par90_share,
        m.npl_kzt / m.portfolio_kzt   AS npl_share,
        t.top10_kzt / m.portfolio_kzt AS top10_share
    FROM m
    JOIN top10 t USING (report_date)
)
SELECT
    s.*,
    lag(s.report_date) OVER w                                AS prev_report_date,
    s.portfolio_kzt / lag(s.portfolio_kzt) OVER w - 1        AS portfolio_change_ratio,
    (s.par30_share - lag(s.par30_share) OVER w) * 100        AS par30_change_pp,
    (s.par90_share - lag(s.par90_share) OVER w) * 100        AS par90_change_pp,
    (s.npl_share - lag(s.npl_share) OVER w) * 100            AS npl_change_pp,
    (s.top10_share - lag(s.top10_share) OVER w) * 100        AS top10_change_pp,
    s.provisions_kzt / lag(s.provisions_kzt) OVER w - 1      AS provisions_change_ratio
FROM s
WINDOW w AS (ORDER BY s.report_date);

-- Разрезы по отрасли, программе и корзине просрочки одним запросом (GROUPING SETS).
CREATE OR REPLACE VIEW reporting.v_risk_by_segment AS
WITH seg AS (
    SELECT
        report_date,
        CASE
            WHEN GROUPING(sector) = 0  THEN 'sector'
            WHEN GROUPING(program) = 0 THEN 'program'
            ELSE 'dpd_bucket'
        END                                   AS dimension,
        COALESCE(sector, program, dpd_bucket) AS segment,
        count(*)                              AS loans_count,
        sum(principal_kzt)                    AS portfolio_kzt,
        sum(par30_kzt)                        AS par30_kzt,
        sum(par90_kzt)                        AS par90_kzt,
        sum(npl_kzt)                          AS npl_kzt,
        sum(provision_kzt)                    AS provisions_kzt
    FROM reporting.v_portfolio
    GROUP BY report_date, GROUPING SETS ((sector), (program), (dpd_bucket))
)
SELECT
    seg.*,
    seg.portfolio_kzt / sum(seg.portfolio_kzt) OVER (PARTITION BY seg.report_date, seg.dimension) AS portfolio_share,
    seg.par30_kzt / seg.portfolio_kzt AS par30_share,
    seg.par90_kzt / seg.portfolio_kzt AS par90_share,
    seg.npl_kzt / seg.portfolio_kzt   AS npl_share,
    (seg.npl_kzt / seg.portfolio_kzt
        - lag(seg.npl_kzt / seg.portfolio_kzt) OVER (PARTITION BY seg.dimension, seg.segment ORDER BY seg.report_date)
    ) * 100                           AS npl_change_pp
FROM seg;

-- Качество данных: что отброшено по дороге из сырого слоя в портфель.
CREATE OR REPLACE VIEW reporting.v_data_quality AS
WITH r AS (
    SELECT report_date::date AS report_date, count(*) AS raw_rows
    FROM raw.portfolio
    GROUP BY 1
),
c AS (
    SELECT
        report_date,
        count(*)                                                           AS unique_rows,
        count(*) FILTER (WHERE is_written_off)                             AS written_off_loans,
        coalesce(sum(principal_kzt) FILTER (WHERE is_written_off), 0)      AS written_off_kzt,
        count(*) FILTER (WHERE fx_rate IS NULL)                            AS loans_without_rate,
        count(*) FILTER (WHERE currency <> 'KZT' AND NOT is_written_off)   AS fx_loans,
        count(*) FILTER (WHERE maturity_date < report_date AND NOT is_written_off) AS past_maturity_loans
    FROM reporting.v_loans_clean
    GROUP BY report_date
)
SELECT
    r.report_date,
    r.raw_rows,
    r.raw_rows - c.unique_rows          AS duplicate_rows,
    c.written_off_loans,
    c.written_off_kzt,
    c.unique_rows - c.written_off_loans AS portfolio_loans,
    c.fx_loans,
    c.loans_without_rate,
    c.past_maturity_loans
FROM r
JOIN c USING (report_date);
