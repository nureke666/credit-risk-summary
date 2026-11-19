# Единая точка входа: поднять Postgres в Docker, загрузить CSV, построить витрины, сверить цифры.
PG       ?= crs-pg
PG_IMAGE ?= postgres:16
PORT     ?= 8765
PSQL      = docker exec -i -e PGOPTIONS=--client-min-messages=warning $(PG) \
            psql -U postgres -d risk -v ON_ERROR_STOP=1 -q

.PHONY: check db load export verify serve screenshot psql down

# Ворота: загрузка дважды (скрипты обязаны быть идемпотентными), семантический слой против
# витрин, выгрузка для дашборда, сверка с независимым пересчётом из CSV.
check: load
	@$(MAKE) --no-print-directory load
	@python3 scripts/check_semantic.py
	@scripts/export.sh
	@python3 scripts/verify.py

# Готовность ждём по TCP: временный сервер init-скрипта слушает только сокет и потом перезапускается.
db:
	@docker start $(PG) >/dev/null 2>&1 || docker run -d --name $(PG) \
	  -e POSTGRES_PASSWORD=postgres -e POSTGRES_DB=risk \
	  -v "$(CURDIR)/data:/data:ro" -v "$(CURDIR)/sql:/sql:ro" $(PG_IMAGE) >/dev/null
	@for i in $$(seq 60); do \
	  docker exec $(PG) pg_isready -q -h 127.0.0.1 -U postgres -d risk && exit 0; sleep 1; \
	done; echo "Postgres не поднялся за 60 секунд" >&2; exit 1

load: db
	@for f in 00_raw 01_load 10_reporting 90_checks; do \
	  $(PSQL) -f /sql/$$f.sql || exit 1; \
	done
	@echo "load: витрины построены, проверки 90_checks пройдены"

export: load
	@scripts/export.sh

verify:
	@python3 scripts/verify.py

serve:
	@echo "Дашборд: http://127.0.0.1:$(PORT)/"
	@python3 -m http.server $(PORT) -d dashboard

screenshot:
	@python3 -m http.server $(PORT) -d dashboard >/dev/null 2>&1 & srv=$$!; \
	google-chrome --headless=new --disable-gpu --hide-scrollbars --window-size=1280,1700 \
	  --virtual-time-budget=20000 --screenshot="$(CURDIR)/docs/dashboard.png" \
	  "http://127.0.0.1:$(PORT)/" >/dev/null 2>&1; rc=$$?; kill $$srv; exit $$rc

psql:
	docker exec -it $(PG) psql -U postgres -d risk

down:
	docker rm -f $(PG)
