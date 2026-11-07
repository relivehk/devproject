# Локальный отказоустойчивый контур мониторинга для Uptime Kuma

Стенд состоит из двух независимых слоёв (Docker Compose), жизненным циклом
которых управляет Dagger-модуль в корне репозитория.

Приложение и БД: Uptime Kuma 2.x, MariaDB 11.4 (данные на named volume)
Наблюдаемость: Prometheus, Grafana, node-exporter, cAdvisor, mysqld-exporter, blackbox-exporter

Оба слоя подключены к общей docker-сети `kuma-net`, поэтому мониторинг
видит контейнеры приложения по именам.

## Структура репозитория

```
.
├── dagger.json / .dagger/main.go      Dagger-модуль (Go SDK)
├── compose/app/                       MariaDB + Uptime Kuma
│   ├── docker-compose.yml
│   └── init/01-exporter.sh            создание пользователя для mysqld-exporter
├── compose/monitoring/                Prometheus, Grafana, экспортёры
│   ├── docker-compose.yml
│   ├── prometheus/{prometheus.yml,alerts.yml}
│   ├── blackbox/blackbox.yml
│   ├── mysqld-exporter/.my.cnf
│   └── grafana/dashboards/*.json      дашборды, импортируемые через Grafana API
├── scripts/
│   ├── configure-grafana.sh           datasource + дашборды через HTTP API
│   ├── validate.sh                    проверка здоровья всех компонентов
│   └── chaos.sh                       chaos-тест
├── .env.example                       шаблон переменных окружения
├── README.md
└── AI_REVIEW.md
```

## Требования

- Linux (проверено на Ubuntu Server 26.04); macOS/Windows — через Docker Desktop / WSL2
- Docker Engine 28+ с плагином Compose v2
- Dagger CLI 0.21+ (`curl -fsSL https://dl.dagger.io/dagger/install.sh | BIN_DIR=/usr/local/bin sudo -E sh`)
- Пользователь в группе `docker` (`sudo usermod -aG docker $USER`, перелогиниться)
- Рекомендуется минимум 2 vCPU и 4 ГБ RAM
- Свободные порты: 3000 (Grafana), 3001 (Uptime Kuma), 9090 (Prometheus)

Go локально не нужен: Dagger собирает модуль внутри своего контейнера.

## Подготовка окружения

```bash
git clone <url> devproject && cd devproject
cp .env.example .env
```

Откройте `.env` и задайте:

- пароли MariaDB, пользователя-экспортёра и администратора Grafana;
- `HOST_PROJECT_DIR` — **абсолютный путь к этому каталогу на хосте** (`pwd`).
  Он нужен, потому что `docker compose` выполняется внутри контейнера Dagger,
  а Docker-демон монтирует конфиги по путям хоста.

`.env` в репозиторий не попадает (`.gitignore`); в Dagger он передаётся как секрет.

## Запуск

Все команды выполняются из корня репозитория. Dagger управляет хостовым
Docker через проброшенный сокет `/var/run/docker.sock`, а `.env` получает
как секрет (`file:.env`) — его содержимое не попадает в логи и кэш.

```bash
# 1. MariaDB + Uptime Kuma (ждёт healthy обоих контейнеров)
dagger call deploy-app --docker=/var/run/docker.sock --env-file=file:.env

# 2. Prometheus, Grafana, экспортёры
dagger call deploy-monitoring --docker=/var/run/docker.sock --env-file=file:.env

# 3. Datasource и дашборды через Grafana API (идемпотентно)
dagger call configure-grafana --docker=/var/run/docker.sock --env-file=file:.env
```

Одной командой (бонус): поднимает всё и валидирует:

```bash
dagger call deploy-all --docker=/var/run/docker.sock --env-file=file:.env
```

Первый вызов скачивает Dagger Engine и образы — занимает несколько минут.

Другие команды модуля:

```bash
dagger call validate --docker=/var/run/docker.sock --env-file=file:.env   # проверка состояния
dagger call destroy  --docker=/var/run/docker.sock --env-file=file:.env   # остановить оба стека (volumes сохраняются)
dagger functions                                                         # список всех команд
```

## Доступ к сервисам


Uptime Kuma: http://localhost:3001
Grafana: http://localhost:3000     ## `GRAFANA_ADMIN_USER` / `GRAFANA_ADMIN_PASSWORD` из `.env`
Prometheus: http://localhost:9090

Вместо `localhost` подставьте IP сервера, если стенд развёрнут на удалённой машине.

Дашборд здоровья контура: **«Так и поплывём»** —
http://localhost:3000/d/<UID>/ (uid указан в `compose/monitoring/grafana/dashboards/kuma-stand-health.json`).

На дашборде:
- статус MariaDB (`mysql_up`), Uptime Kuma по HTTP (`probe_success`), всех targets Prometheus;
- CPU и память контейнеров `mariadb` и `uptime-kuma` (cAdvisor);
- latency HTTP-проверки Uptime Kuma (blackbox);
- соединения, QPS и uptime MariaDB (mysqld-exporter);
- CPU, RAM, диск хоста (node-exporter).

## Проверка работоспособности

Автоматически:

```bash
dagger call validate --docker=/var/run/docker.sock --env-file=file:.env
```

Проверяет статус/healthcheck всех восьми контейнеров, что все targets
Prometheus в состоянии `up`, и что каждый дашборд из репозитория есть в Grafana.
Ожидаемый финал: `RESULT: ALL OK`.

Вручную:

```bash
docker ps --format 'table {{.Names}}\t{{.Status}}'
docker logs uptime-kuma 2>&1 | grep -i 'database type'          # Database Type: mariadb
curl -s localhost:9090/api/v1/targets | jq -r '.data.activeTargets[] | "\(.labels.job)\t\(.health)"'
curl -s localhost:9090/api/v1/query --data-urlencode 'query=mysql_up' | jq '.data.result[0].value[1]'
```

Персистентность: `dagger call destroy ...` → `dagger call deploy-app ...` —
учётная запись и мониторы в Uptime Kuma сохраняются (volume `kuma-app_mariadb-data`).

## Chaos-тест

```bash
# docker stop (как в ТЗ): остановка → DOWN на дашборде → docker start → UP
dagger call chaos --docker=/var/run/docker.sock --env-file=file:.env --target=mariadb --mode=stop

# имитация падения процесса: SIGKILL в обход Docker → DOWN → restart-policy → UP
dagger call chaos --docker=/var/run/docker.sock --env-file=file:.env --target=mariadb --mode=crash
dagger call chaos --docker=/var/run/docker.sock --env-file=file:.env --target=uptime-kuma --mode=crash
```

Скрипт опрашивает Prometheus (ту же метрику, что stat-панель на дашборде),
фиксирует переход в `0` («Все Плохо», панель красная), затем возврат в `1`
и выводит `RestartCount` контейнера. Вывод теста является подтверждением
обоих пунктов ТЗ: (а) переход в статус «Все Плохо» и (б) восстановление
сервиса с отражением на дашборде.

**Почему два режима.** `docker stop` (и `docker kill`) для Docker — ручная
остановка: контейнер помечается как остановленный пользователем, и
restart-policy `unless-stopped` по правилам Docker не срабатывает. Поэтому в
режиме `stop` восстановление выполняется явным `docker start`. Режим `crash`
убивает главный процесс контейнера сигналом с уровня хоста — для Docker это
аварийное завершение (exit 137), и контейнер поднимается restart-policy
самостоятельно; тест проверяет, что `RestartCount` вырос.

## Безопасность

- Все пароли только в `.env` (не в git); в Dagger передаются как `Secret`,
  а каталог исходников загружается с исключением `.env`.
- Порт MariaDB 3306 наружу не публикуется — БД доступна только внутри `kuma-net`.
- Для mysqld-exporter создан отдельный пользователь с правами
  `PROCESS, REPLICATION CLIENT, SLAVE MONITOR, SELECT` и лимитом соединений.
- Grafana: анонимный доступ и саморегистрация отключены.
- Версии всех образов зафиксированы.
- У всех основных сервисов есть healthcheck; Uptime Kuma стартует только после
  `healthy` MariaDB.

## Известные особенности окружения

- **containerd image store.** Новые установки Docker используют containerd
  image store (`Storage Driver: overlayfs`). cAdvisor младше 0.54 не умеет
  читать метаданные контейнеров в этом режиме и не отдаёт per-container метрики;
  в стенде используется `ghcr.io/google/cadvisor` ≥ 0.54. Альтернатива —
  переключить Docker на `overlay2` через `daemon.json`.
- **Ubuntu 26.04.** Если в apt-репозитории Docker ещё нет кодового имени
  релиза, используйте репозиторий для `noble`.
- **Кэш Dagger.** Команды деплоя имеют побочные эффекты, поэтому в модуле
  установлена переменная `CACHEBUSTER` — без неё повторный вызов возвращал бы
  закэшированный результат, не запуская `docker compose`.

## Остановка и очистка

```bash
dagger call destroy --docker=/var/run/docker.sock --env-file=file:.env   
docker volume rm kuma-app_mariadb-data kuma-app_kuma-data \
                 kuma-monitoring_prometheus-data kuma-monitoring_grafana-data  
docker network rm kuma-net
```
