-- Полная перезагрузка сырого слоя в одной транзакции: повторный запуск даёт то же состояние.
-- Пути — внутри контейнера, data/ смонтирована в /data (см. Makefile, цель db).
BEGIN;
TRUNCATE raw.portfolio, raw.fx;
\copy raw.portfolio (report_date, loan_id, borrower_id, group_id, sector, program, currency, issue_date, maturity_date, principal_outstanding, days_past_due, restructured, written_off) FROM '/data/portfolio.csv' WITH (FORMAT csv, HEADER true)
\copy raw.fx (date, currency, rate_kzt) FROM '/data/fx.csv' WITH (FORMAT csv, HEADER true)
COMMIT;
