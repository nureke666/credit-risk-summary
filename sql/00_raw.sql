-- Сырой слой: CSV как есть, все колонки text, чтобы загрузка не падала на кривом значении.
-- Типы и правила появляются в витринах reporting.*, там же падает всё, что не приводится.
CREATE SCHEMA IF NOT EXISTS raw;
CREATE SCHEMA IF NOT EXISTS reporting;

CREATE TABLE IF NOT EXISTS raw.portfolio (
    report_date           text,
    loan_id               text,
    borrower_id           text,
    group_id              text,
    sector                text,
    program               text,
    currency              text,
    issue_date            text,
    maturity_date         text,
    principal_outstanding text,
    days_past_due         text,
    restructured          text,
    written_off           text
);

CREATE TABLE IF NOT EXISTS raw.fx (
    date     text,
    currency text,
    rate_kzt text
);
