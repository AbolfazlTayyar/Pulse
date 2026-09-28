# market: worker قیمت لحظه‌ای کریپتو

یک برنامهٔ خط فرمان کوچک با Lua 5.4 که سرویس‌های دیگر ممکن است در هر ثانیه چند بار اجرایش کنند.
آرگومان می‌گیرد، **یک شیء JSON روی stdout** چاپ می‌کند، لاگ‌ها را خط‌به‌خط و به شکل JSON روی
stderr می‌نویسد و با یک exit code معنادار بیرون می‌رود. قیمت‌ها را از یک API عمومی بازار می‌گیرد
(پیش‌فرض CoinGecko)، به یک schema نسخه‌دار (`ticker.v1`) تبدیلشان می‌کند که در آن قیمت‌ها رشتهٔ
دهدهی دقیق‌اند، و با **Redis** کاری می‌کند که پروسه‌های هم‌زمان یک قفل، یک rate limit و یک
مجموعه snapshot از آخرین دادهٔ سالم را با هم شریک باشند. نتیجه این‌که ۲۰۰ اجرای موازی `fetch`
فقط یک درخواست به vendor می‌زنند. هیچ HTTP server یا پورت بازی هم در کار نیست.

- طراحی: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) (خلاصهٔ فارسی: [docs/ARCHITECTURE.fa.md](docs/ARCHITECTURE.fa.md)) · تصمیم‌ها: [docs/adr/](docs/adr/README.md)
- نتایج تست بار: [docs/LOAD.md](docs/LOAD.md) · نمونهٔ میزبان: [scripts/host_example.py](scripts/host_example.py)

## شروع سریع با Docker Compose

Docker همراه با Compose لازم است. پوشهٔ پروژه داخل کانتینر `app` مونت می‌شود و
`REDIS_HOST=redis` هم همان‌جا تنظیم شده.

```bash
docker compose build                                           # Lua 5.4 و وابستگی‌های luarocks (یک بار)
docker compose up -d redis                                     # بالا آوردن Redis
docker compose run --rm app lua market.lua fetch BTC           # یک fetch زنده
docker compose run --rm app lua market.lua health              # پینگ Redis، آخرین fetch، cooldown
docker compose run --rm app sh scripts/load.sh                 # ۲۰۰ اجرای fetch، ۵۰ تا هم‌زمان
docker compose run --rm app busted                             # تست‌ها
```

روی Docker Desktop در ویندوز و macOS، هر پروسه‌ای که از روی bind mount اجرا شود حدود ۷۰
میلی‌ثانیه پای دسترسی به فایل‌ها معطل می‌شود. اگر می‌خواهید عددهای تست بار به یک میزبان لینوکسی
نزدیک باشد، از یک کپی داخل خود کانتینر اجرا کنید:
`docker compose run --rm app sh -c 'cp -r /app /tmp/app && cd /tmp/app && sh scripts/load.sh'`
(جزئیات در [docs/LOAD.md](docs/LOAD.md)).

## شروع سریع روی لینوکس یا WSL

میزبان واقعی برنامه را همین‌طور اجرا می‌کند: مستقیم با `lua market.lua ...`. (این مراحل در ۲۷
سپتامبر ۲۰۲۶ روی یک کانتینر تمیز Ubuntu 24.04 قدم‌به‌قدم امتحان شده؛ روی یک WSL واقعی هنوز نه.)

```bash
sudo apt install lua5.4 liblua5.4-dev luarocks build-essential libssl-dev
sudo update-alternatives --set lua-interpreter /usr/bin/lua5.4   # lua پیش‌فرض توزیع 5.1 است
luarocks --lua-version=5.4 install --local --only-deps market-dev-1.rockspec
eval "$(luarocks --lua-version=5.4 path)"                        # rockهای --local و ~/.luarocks/bin
docker compose up -d redis                                       # یا هر Redis در دسترس دیگری
export REDIS_HOST=127.0.0.1
lua market.lua fetch BTC
lua market.lua health
sh scripts/load.sh                                               # ۲۰۰ اجرای fetch، ۵۰ تا هم‌زمان
busted                                                           # تست‌ها (به Redis داخل compose نیاز دارند)
```

برای `REDIS_HOST` بهتر است IP بدهید (یا زمان resolver را با `RES_OPTIONS="timeout:1 attempts:1"`
محدود کنید)، چون resolve کردن نام میزبان تنها مرحله‌ای است که luasocket نمی‌تواند برایش timeout
بگذارد.

## دستورها

| دستور | کارش |
|---|---|
| `lua market.lua fetch BTC,ETH,SOL` | قیمت لحظه‌ای (۵ ثانیه cache می‌شود و همهٔ پروسه‌ها از همان استفاده می‌کنند) |
| `lua market.lua snapshot --symbols BTC,ETH` | فقط قیمت‌های cache‌شده؛ هیچ‌وقت سراغ vendor نمی‌رود |
| `lua market.lua convert --from BTC --to USDT --amount 1.5` | تبدیل دقیق بر اساس قیمت‌های cache‌شده |
| `lua market.lua health` | پینگ Redis، آخرین fetch، تعداد درخواست‌ها به vendor، cooldown |
| `lua market.lua daemon` | درخواست‌ها به صورت NDJSON از stdin، هر پاسخ در یک خط |

نمادها فقط از `A-Z0-9` تشکیل می‌شوند، ۱ تا ۱۵ کاراکتر، با کاما از هم جدا (تکراری‌ها حذف
می‌شوند) و حداکثر ۵۰ تا در هر اجرا. مبلغ باید یک عدد دهدهی مثبت باشد با حداکثر ۳۰ رقم صحیح و ۱۸
رقم اعشار. هر ورودی که یکی از کاراکترهای ``; | & $ ` ( ) < > \ ' "``، فاصله یا کاراکتر کنترلی
داشته باشد رد می‌شود (`BAD_ARGS`، exit 2). آرگومان‌ها هیچ‌وقت به shell نمی‌رسند.

## قرارداد اجرا

| | |
|---|---|
| **argv** | `lua /path/to/market.lua <command> [args]` به صورت لیست آرگومان، هیچ‌وقت از طریق shell |
| **cwd** | فرقی نمی‌کند (پایین‌تر توضیح داده‌ام) |
| **env** | جدول پایین؛ فقط `REDIS_HOST` اجباری است. همه یک بار موقع شروع بررسی می‌شوند و هر مقدار نامعتبر یعنی `BAD_CONFIG` با exit 2 |
| **stdout** | دقیقاً **یک** شیء JSON در یک خط (در daemon: یک شیء به ازای هر خط ورودی). چیز دیگری آن‌جا چاپ نمی‌شود، پس کل stdout همان payload است |
| **stderr** | لاگ، هر خط یک شیء JSON (`ts`، `level`، `inv`، `event` و ...)؛ رمز و اطلاعات محرمانه هیچ‌وقت در آن نمی‌آید. برای خواندن راحت‌تر: `lua market.lua fetch BTC 2> >(jq -c .)` |
| **exit code** | `0` موفق · `1` خطای منطقی یا upstream (بدنهٔ JSON باز هم روی stdout هست) · `2` آرگومان یا تنظیمات نامعتبر · `3` Redis در دسترس نیست |
| **زمان** | هر اجرا حداکثر در `DEADLINE_MS` (۴ ثانیه) تمام می‌شود؛ timeout میزبان برای kill کردن را بیشتر از این بگذارید |

**پوشهٔ جاری و `LUA_PATH`.** `market.lua` پوشهٔ خودش را (از روی `arg[0]`) اول `package.path`
می‌گذارد، برای همین `cd / && lua /opt/market/market.lua health` بدون هیچ تنظیمی کار می‌کند. معادل
دستی‌اش این است: `LUA_PATH="/opt/market/?.lua;/opt/market/?/init.lua;;"` (آن `;;` آخر مسیر
پیش‌فرض Lua را برای ماژول‌های luarocks نگه می‌دارد).

**کدهای خطا** (ثابت‌اند و عوض نمی‌شوند): `BAD_ARGS`، `BAD_CONFIG`، `UNKNOWN_SYMBOL`،
`SOURCE_UNAVAILABLE`، `RATE_LIMITED`، `BAD_PAYLOAD`، `PRICE_UNAVAILABLE`، `REDIS_UNAVAILABLE`،
`DEADLINE_EXCEEDED`، `INTERNAL_ERROR`.

### متغیرهای محیطی

| متغیر | پیش‌فرض | کاربرد |
|---|---|---|
| `REDIS_HOST` | **اجباری** | آدرس Redis؛ هیچ مقدار پیش‌فرضی ندارد |
| `REDIS_PORT` / `REDIS_PASSWORD` | `6379` / خالی | پورت Redis و رمز اختیاری |
| `REDIS_TIMEOUT_MS` | `200` | timeout اتصال و خواندن برای هر عملیات Redis |
| `MARKET_SOURCE` | `coingecko` | `coingecko`، `binance` یا `kraken` |
| `MARKET_QUOTE` | `USD` | ارز مبنا (Binance جفت USD ندارد، پس قیمت را به USDT می‌دهد و در خروجی هم همین را می‌نویسد) |
| `SOURCE_URL` | آدرس خود adapter | عوض کردن آدرس vendor (برای mock و fixture) |
| `SOURCE_TIMEOUT_MS` | `2000` | timeout درخواست HTTP به vendor |
| `DEADLINE_MS` | `4000` | کل زمان مجاز هر اجرا؛ کمتر از timeout میزبان نگهش دارید |
| `LOCK_TTL_MS` | `3000` | TTL قفل single-flight؛ باید `SOURCE_TIMEOUT_MS < LOCK_TTL_MS < DEADLINE_MS` برقرار باشد |
| `SNAPSHOT_FRESH_S` / `SNAPSHOT_KEEP_S` | `5` / `3600` | مدتی که داده تازه حساب می‌شود و دوباره گرفته نمی‌شود / مدت نگه‌داری آخرین دادهٔ سالم |
| `RATE_LIMIT_WINDOW_S` / `RATE_LIMIT_PER_WINDOW` | `10` / `5` | سقف مشترک تعداد درخواست به vendor |
| `MAX_CONCURRENT_UPSTREAM` | `1` | تعداد درخواست هم‌زمان به هر منبع (فقط `1` قبول می‌شود) |
| `CACHE_MAX_ENTRIES` / `CACHE_MAX_BYTES` | `256` / `1048576` | سقف LRU داخل پروسه در حالت daemon |
| `CONVERT_SCALE` | `8` | تعداد رقم اعشار نتیجهٔ `convert` (گرد کردن half-even) |
| `LOG_LEVEL` | `info` | `debug`، `info`، `warn`، `error` |

## نمونهٔ خروجی

`fetch` (دادهٔ زنده، اولین اجرا در بازهٔ ۵ ثانیه‌ای؛ اجراهای بعدی `"cache":"hit"` و `"http_ms":0` دارند):

```json
{"ok":true,"schema":"ticker.v1","as_of_unix":1790528981,"source":"coingecko","items":[{"symbol":"BTC","quote":"USD","price":"84378","volume_24h":"21954198073.562046","change_24h_pct":"0.36808338666521584","as_of_unix":1790528981,"stale":false}],"errors":[],"meta":{"cache":"miss","partial":false,"redis_ms":3,"http_ms":593}}
```

`fetch BTC,FAKECOIN` موفقیت نسبی حساب می‌شود (exit 0): BTC در `items` می‌آید،
`{"symbol":"FAKECOIN","code":"UNKNOWN_SYMBOL",...}` در `errors`، و `"partial":true` است.

`snapshot --symbols BTC,DOGE` وقتی فقط BTC در cache هست (exit 0؛ اگر هیچ‌کدام نباشد exit 1):

```json
{"ok":true,"schema":"ticker.v1","as_of_unix":1790527647,"source":"coingecko","items":[{"symbol":"BTC","quote":"USD","price":"67210.12","volume_24h":"12345.67","change_24h_pct":"-1.24","as_of_unix":1790527647,"stale":false}],"errors":[{"symbol":"DOGE","code":"PRICE_UNAVAILABLE","detail":"no cached price for DOGE"}],"meta":{"cache":"hit","partial":true,"redis_ms":1,"http_ms":0}}
```

`convert --from BTC --to USDT --amount 1.5` وقتی در cache داریم BTC = 67210.12 USD و USDT = 1.00002813 USD:

```json
{"ok":true,"schema":"convert.v1","as_of_unix":1790528322,"stale":false,"source":"coingecko","from":"BTC","to":"USDT","amount":"1.5","result":"100812.34414876","rate":"67208.22943251","legs":[{"symbol":"BTC","quote":"USD","price":"67210.12","as_of_unix":1790528324,"stale":false},{"symbol":"USDT","quote":"USD","price":"1.00002813","as_of_unix":1790528322,"stale":false}],"meta":{"cache":"hit","redis_ms":1,"http_ms":0}}
```

`health` (exit 0؛ اگر Redis پایین باشد همین بدنه با `"ok":false` و `"redis":{"ok":false,...}` برمی‌گردد و exit 3 است):

```json
{"ok":true,"schema":"health.v1","as_of_unix":1790528983,"process":{"ok":true,"lua":"Lua 5.4","version":"0.1.0"},"redis":{"ok":true,"latency_ms":1},"source":{"name":"coingecko","last_fetch_unix":1790528981,"last_fetch_age_s":2,"vendor_calls":1,"cooldown_active":false}}
```

`daemon`: هر خط stdin یک درخواست و هر خط stdout یک پاسخ است. `id` عیناً برگردانده می‌شود و با
رسیدن EOF برنامه با exit 0 تمام می‌شود.

```bash
printf '%s\n' '{"id":"1","command":"fetch","symbols":["BTC"]}' \
              '{"id":"2","command":"snapshot","symbols":["BTC"]}' | lua market.lua daemon
# {"id":"1","ok":true,...,"meta":{"cache":"miss",...}}
# {"id":"2","ok":true,...,"meta":{"cache":"memory",...}}     <- جوابش از LRU داخل پروسه آمده
```

## جاهایی که با مثال‌های صورت تمرین فرق دارد

- **ارز مبنا `USD` است، نه `USDT`** ([ADR 0015](docs/adr/0015-usd-quote-with-cross-rate-conversion.md)):
  CoinGecko قیمت را به ارز فیات می‌دهد. `convert --to USDT` از طریق قیمت دلاری خود USDT حساب می‌شود.
- **اگر Redis پایین باشد، برنامه کار نمی‌کند** ([ADR 0009](docs/adr/0009-fail-closed-when-redis-unavailable.md)):
  exit 3 با `REDIS_UNAVAILABLE`. بدون Redis هیچ هماهنگی‌ای بین workerها نیست و همه با هم روی
  vendor می‌ریزند.
- **موفقیت نسبی** ([ADR 0010](docs/adr/0010-partial-success-semantics.md)): نمادهای ناشناخته و
  ردیف‌های خراب vendor با دلیلشان در `errors[]` می‌روند، بقیه برگردانده می‌شوند و exit 0 است.
- **خطای vendor یعنی exit 1، ولی آخرین دادهٔ سالم هم همراهش می‌آید**
  ([ADR 0011](docs/adr/0011-vendor-failure-returns-error-with-last-good-data.md)): `ok:false` با
  یکی از `SOURCE_UNAVAILABLE` / `RATE_LIMITED` / `BAD_PAYLOAD` / `DEADLINE_EXCEEDED`، و بدنه
  همچنان همهٔ آیتم‌های cache‌شده را دارد؛ هر کدام که قدیمی باشد با `stale` مشخص می‌شود.
- **هر آیتم `as_of_unix` و `stale` خودش را دارد** و `as_of_unix` سطح بالا مال قدیمی‌ترین آیتم است
  ([ADR 0003](docs/adr/0003-versioned-output-schema-ticker-v1.md)).

## ساختار پوشه‌ها

```
market.lua          نقطهٔ ورود: argv -> اعتبارسنجی -> config -> دستور -> یک خط JSON -> exit code
src/                cli, config, output, log, deadline, decimal, normalize, redis_client, lock,
                    limiter, snapshot, cache, commands/, source/ (coingecko, binance, kraken)
tests/              specهای busted، fixtures/، support/ (اجراکنندهٔ پروسه، stub برای vendor)
scripts/            load.sh, host_example.py
docs/               ARCHITECTURE.md، LOAD.md، adr/، صورت تمرین
```
