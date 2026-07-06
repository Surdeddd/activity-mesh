# activity-mesh — план исправлений и укрепления (по аудиту 2026-07-06)

**Источник**: полный аудит кода + архитектуры + живого деплоя (macbook + mac-mini) + веб-проверка ландшафта.
**Цель**: закрыть P0/P1, вернуть ценность живому деплою, довести проект до сильного универсального публикуемого состояния.
**Скоуп-гард**: НЕ трогаем формат шардов и схему событий (v:1 остаётся), не делаем multi-tenant, не начинаем v2 action-propagation, не меняем стек (Go + JSONL + SQLite + Syncthing).

---

## Фаза 0 — стоп-кровь на живом деплое (конфиг/деплой, без изменений кода)

Verifiable goal: `health/master.sh` зелёный на обоих хостах, алерт доходит до Telegram при симуляции падения.

1. **Ребилд + редеплой бинарей из HEAD на оба хоста**: daemon от 5 мая (2 месяца), watcher на macbook от 26 мая (без fd-фикса 650abff, который на mini уже есть). `make build build-daemon` → `~/.local/bin` на обоих; `launchctl kickstart -k`.
2. **Починить мёртвый алертинг**: `master.sh` шлёт только через несуществующий `notify-maxim` → добавить прямой Telegram-fallback (тот же паттерн, что в `dead-man-heartbeat.sh:107-162`); добавить `TELEGRAM_ENV` в health plist. Health красный неделями — ноль уведомлений.
3. **Убрать два вечно-красных чека** (alert fatigue):
   - `digest-freshness`: порог 2h против еженедельного писателя → порог 8d;
   - `schema-drift`: скоуп `infra:heartbeat` (49% всех событий!) не в registry → добавить в `scopes.yaml` (`router: false`), опубликовать registries в `~/Sync/activity/` (сейчас там только scopes.yaml — kinds-валидация слепа).
4. **token-budget чек**: читает `/tmp/activity-tokens-*`, а роутер пишет `$STATE/tokens-<session>` → поправить путь в чеке (телеметрия на нуле с d286c04).
5. **Унификация state-дирок**: health/weekly-digest пишут в `~/.local/log/`, heartbeat в `~/.local/state/`, compact env указывает третье → один канон (`~/.local/state/activity-mesh` для state, `~/.local/log/activity-mesh` только для логов), правки в plists; вычистить мёртвые May-6 остатки на обоих хостах, 3 `.bak-pre-pathfix` plists, `.bak` бинари.
6. **Закоммитить живой uncommitted-код**: `ci.yml` (hook-tests job) и `session-start-digest.sh` — но фильтр heartbeat переделать с `grep -v 'heartbeat'` (съедает и легитимные события со словом heartbeat) на исключение по kind (см. Ф2.7).
7. **weekly-digest на mini**: либо поставить job, либо задокументировать single-source и убрать warn из чека mini.
8. **launchd-jobs чек**: мониторит 4 из 6 джобов → добавить compact + weekly-digest.

## Фаза 1 — P0 в коде

Verifiable goal: новые тесты на гонку и traversal красные до фикса, зелёные после; `make verify` чистый.

1. **Гонка compaction ↔ emit (потеря событий)**: emit держит flock только внутри `nextSeq` и отпускает до append (`pkg/event/lock.go`, `cmd/activity-log/main.go:252-294`); compact держит лок и переписывает шард секунды → append в окно уничтожается. Фикс: единый `pkg/shard.Append` — flock на весь путь append (emit, и daemon `/push` туда же); тест с конкурентным emit во время compact.
2. **`/push` path traversal**: `p.Host` без валидации → `filepath.Join(syncDir, "events-"+p.Host+".jsonl")` — `"host":"../../..."` пишет в произвольный файл (`server/main.go:351,389`). Фикс: `^[A-Za-z0-9._-]+$` + запрет `..`; ULID-валидация `id` (мусорный id ломает `MAX(ulid)` навсегда).
3. **`/push` мимо редакции** — секреты по HTTP ложатся в шарды нередактированными: прогонять `redact.ApplyJSON` + sanitize + audit hits (общий код с emit).
4. **Daemon bind на все интерфейсы**: `Addr: ":"+port` → default `127.0.0.1`, флаг `--bind` для сознательного расширения. Сейчас любой в LAN читает всю историю и пишет события, которые потом инжектятся в контекст LLM (prompt-injection вектор).
5. **Newline self-heal**: append-еры не проверяют, кончается ли шард `\n` (compact сознательно сохраняет оборванный хвост) → склейка двух событий в одну битую строку. Фикс в `pkg/shard.Append`.

## Фаза 2 — P1 корректность

Verifiable goal: тест-кейсы на каждый пункт; `make verify` + hook-suite зелёные.

1. **redact**: `sk-` без левой границы мажет «risk-assessment-…» (`redact.go:49` → `\bsk-`); `lan_ip` 10.x ловит только 3 октета и false-positive'ит версии «10.15.7» (`redact.go:132`); `/Users/maksimkravcov` хардкод → динамический `$HOME` всех известных хостов + env; добавить современные паттерны (gho_/ghu_/ghr_, glpat-, AIza, sk_live_/rk_live_, hf_, sk-or-v1); негативные тесты на false positives.
2. **query --since не парсит RFC3339 ts** (`main.go:363-366`): единый 3-layout парсер, шарится между index/compact/query (сейчас триплицирован).
3. **index**: cursor без идентичности файла — не-строго-меньший rewrite (Syncthing replace) молча теряет хвост → хранить hash первой строки/last-ULID с offset, сбрасывать на mismatch; `IngestJSONL` читает весь файл при каждом fsnotify → `Seek(cursor)`; `count++` по `INSERT OR IGNORE` без `RowsAffected` — метрики врут; FTS-запрос оборачивается одной фразой — многословный поиск требует adjacency → токенизировать по словам.
4. **daemon**: clamp `limit`/`hours` (сейчас `limit=0` = вся таблица в память); лог + errors.Add на проглоченных ingest-ошибках (`main.go:87,357`).
5. **nextSeq crash-safety**: truncate→write → пустой seq-файл при падении между ними → перезапись фикс-шириной или temp+rename под тем же локом.
6. **hooks**: кириллический «антон» не матчится (в `AGENT_RE` только `anton`+гомоглиф); агент-имена захардкожены → генерить `agents-cache` из `agents.yaml` (как scopes-cache, `refresh-scopes` → `refresh-caches`); `/usr/bin/jq` абсолютным путём → резолв с fallback; `secret-redactor.sh` без `~/.local/bin` fallback (parity с остальными — сейчас под launchd молча pass-through без редакции).
7. **CLI**: `--exclude-kind` для query (чистое решение фильтра heartbeat/canary в L2-дайджесте вместо grep); `--version` флаг (ldflags уже прокинуты, флага нет).
8. **MCP server**: `activity_search` описан как «FTS5», реально линейный скан в JS → либо гонять через реальный индекс (новый `activity-log search`), либо честное описание; protocol negotiation (эхо клиентской версии, база 2025-03-26+, сейчас захардкожен 2024-11-05 — стабильный спек уже 2025-11-25); `yesterday` окно = «последние 48h» вместо вчера.
9. **compact**: `--keep 0h`/отрицательный архивирует всё включая сегодня → валидация; fsync каталога архива при создании файла.

## Фаза 3 — универсализация (сильный публичный проект)

Verifiable goal: чистый чекаут на новой машине → `bootstrap.sh` → рабочая система без единого «maxim» в конфиге; `git ls-files | grep bin/` пуст.

1. **Личное из репо**: `agents.yaml`/`scopes.yaml` с ботами Максима → `registries/examples/`; живые registries — в sync-dir (канон уже так задуман); `notify-maxim` → конфигурируемый notify-hook (env `ACTIVITY_MESH_NOTIFY_CMD` + telegram-настройки только через env); дефолтный chat_id 466332453 убрать; `com.maxim.*` паттерны из watcher-конфига → примеры; `~/.hermes` и пр. — в example-конфиг.
2. **Бинари из git (57MB) → GitHub Releases**: goreleaser v2 + GitHub Actions release workflow, sha256 checksums; `bootstrap.sh` качает с checksum-верификацией (сейчас curl без проверки).
3. **Daemon на modernc.org/sqlite** (cgo-free, FTS5 включён — [pkg.go.dev/modernc.org/sqlite](https://pkg.go.dev/modernc.org/sqlite)) → кросс-компиляция всех трёх бинарей на все платформы, `make build` единый, ограничение «daemon build natively on target» снимается.
4. **bootstrap ставит все 6 юнитов** (сейчас 2 из 6 — health/heartbeat/digest/compact руками), публикует registries в sync-dir, `--uninstall` parity.
5. **pkg/shard**: единый append + канонические ts-layouts (выросло из Ф1.1) — снимает дупликацию CLI/daemon.
6. **Доки = реальность**: age-шифрование аудита и NER tier-3 заявлены, не реализованы → в доках честно пометить v2 (или реализовать age — решение при ревью фазы); таблица 11 auto-capture sources → фактическое состояние; ARCHITECTURE к текущему поведению.
7. **MCP protocol bump** (2025-11-25 базово, RC 2026-07-28 отслеживать — [blog.modelcontextprotocol.io](https://blog.modelcontextprotocol.io/posts/2026-07-28-release-candidate/)): version negotiation, tool annotations (readOnlyHint на все 3 тула), structuredContent.

## Фаза 4 — вернуть ценность (adoption)

Verifiable goal: недельный digest ≥30% событий не-canary; hermes/openclaw снова пишут.

1. **Adoption collapse 4 июня**: hermes/openclaw/cron-эмиттеры молчат 32 дня (в 30d-окне 49% canary + 32% handoff, агенты только cli+heartbeat) — диагностика на mini: что сломало эмиты у hermes/openclaw (вне этой репы; вероятно, смена CLI-поверхности v0.2.0 как у хуков), починить интеграции.
2. **git post-commit hook**: задокументирован (ARCHITECTURE:93), не установлен нигде, 0 событий kind=project за всё время → `activity-log install-git-hook [repo]` + поставить на активные репы.
3. **watcher**: паттерн launchd-источника `com.maxim.*` не видит `com.activity-mesh.*` → расширить; sources skill-installed/claude-md ни разу не сработали → проверить пути/паттерны.
4. **Роутер-сигнал**: 67% срабатываний «no events intent=status» — status-события вернутся с adoption; перепроверить окна после Ф4.1.

## Фаза 5 — верификация (сквозная)

1. `make verify` (vet+test+shellcheck) + hook-suite; новые тесты: compact-гонка, push traversal/redaction, redact false-positives, cursor identity, FTS multiword.
2. e2e на живой системе: emit на mini → syncthing → индекс macbook → L3 inject; `master.sh` все ok/ок на обоих хостах; kill daemon → 3 misses → telegram-алерт реально приходит.
3. CHANGELOG + VERSION → 0.3.0, коммиты по фазам (см. Karpathy: surgical, по одному концерну).

---

## Порядок и оценка

Ф0 (полдня, конфиг) → Ф1 (день, код+тесты) → Ф2 (1-2 дня) → Ф3 (1-2 дня) → Ф4 (день, частично вне репы) → Ф5 сквозная. Ф3 и Ф4 можно параллелить.

## Решения, нужные от Максима

1. **`/push` оставить или выпилить?** Ломает single-writer инвариант по построению. Рекомендация: оставить + захарденить (Ф1.2-1.4) — он нужен hermes-у как HTTP-путь.
2. **modernc.org/sqlite миграция** — меняет драйвер демона. Рекомендация: да (снимает cgo, даёт полную кросс-компиляцию).
3. **Готовить репо к публичности** (Ф3.1 полностью) или пока остаётся личным (тогда Ф3.1 урезаем до redact/notify)?
4. **Ф4.1 (эмиттеры на mini)** — в этот прогон или отдельной задачей?
