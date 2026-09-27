# CoinGecko fixtures

- `recorded_2026-09-27.json`: a real `/simple/price?ids=bitcoin,ethereum&vs_currencies=usd&include_24hr_vol=true&include_24hr_change=true` response, recorded 2026-09-27.
- `rate_limited_429.json`: a real 429 body (sent with `retry-after: 43`), recorded the same day.
- `simple_price.json`: hand-written in the same shape, with long fractions to test that no digit is lost.
- `missing_field.json`, `html_error.html`: hand-written broken answers.
