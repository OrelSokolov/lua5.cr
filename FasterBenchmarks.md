# FasterBenchmarks — где и как догонять LuaJIT

Дата: 2026-11-08. Отчёт `rake benchmark:report`, min-of-3:
lua5.1 `81cc6da`, luajit `f39267a`, clua `b095ec0`.

## 1. Точка отсчёта

| bench           | lua5.1 | luajit | clua | clua/jit | что в горячем цикле                                   |
|-----------------|--------|--------|------|----------|-------------------------------------------------------|
| nbody           | 4.206  | 0.405  | 1.893| 4.7x     | ~12 строковых табличных доступов (`bj.x`, `bj.vx=…`) + нативный `sqrt`; Lua-вызовов нет |
| fannkuch        | 2.504  | 0.403  | 0.892| 2.2x     | целочисленная арифметика + доступы к массиву          |
| spectral-norm   | 12.011 | 0.304  | 5.896| 19.4x    | `A(i,j)` — Lua-замыкание, 125M вызовов; upvalue-доступы |
| binary-trees    | 1.205  | 0.303  | 1.192| 3.9x     | аллокация таблиц/замыканий (allocation-bound)         |
| nsieve          | 1.703  | 0.402  | 1.093| 2.7x     | таблица-«решето», числовые ключи                      |
| mandelbrot      | 6.208  | 0.504  | 1.393| 2.8x     | чистая float-арифметика; ни вызовов, ни таблиц        |
| series          | 0.704  | 0.303  | 0.592| 2.0x     | `f(omegan*x)` — **нативные** `math.sin`/`cos`, `^`    |
| partialsums     | 1.504  | 0.403  | 0.793| 2.0x     | `Alt(i)`, `Denom(i)` — 1–2 Lua-вызова на итерацию     |
| recursive-fib   | 2.907  | 1.814  | 1.793| 1.0x     | рекурсия; LuaJIT слаб в глубокой рекурсии (трейсы рвутся) — паритет, не победа |
| array3d         | 5.306  | 0.204  | 5.998| 29.4x    | generic-for (`TFORCALL`!) + метод `arr:set` + `image[pos]=p` |
| fasta           | 2.305  | 0.803  | 4.294| 5.3x     | строки, random, таблицы                               |
| scimark-fft     | 24.624 | 0.903  | 7.898| 8.7x     | таблицы чисел + float-арифметика, циклы               |

LuaJIT исполняет array3d одним сфузженным трейсом «без единого
вызова» (call forwarding: тела итератора и `array_set` вшиты в трейс,
~7.5 нс/итер ≈ пара десятков инструкций); у нас ~220 нс/итер —
интерпретируемый generic-for + два реальных вызова с гвардами.

## 2. Диагноз по профилям (perf, 2026-11-08)

- **array3d**: ~45% стенового времени — `GC_mark_from` во всех
  GC-потоках Boehm (27M boxed-элементов `image` = 432 MB
  сканируемой памяти). Главный цикл generic-for **не компилируется**:
  `TFORCALL` → `CompileBail` (`src/jit/compiler.cr:756`) — весь цикл
  интерпретируемый, OSR-попытка сгорает один раз. Компилируются
  только `array_set` и итератор.
- **spectral-norm**: ~70% времени в JIT-коде + **7.2% `jit_getupval`**
  — каждый доступ к upvalue через хелпер. Основное — 125M вызовов
  `A(i,j)` без инлайнинга: на каждый ~12 guard-загрузок в
  `emit_call_fast` (`src/jit/compiler.cr:1202`) + bookkeeping.
- **partialsums**: в пост-оптимизационном IR (`LUA5_JIT_DUMP`) видно:
  на итерацию 1–2 JIT→JIT вызова `Alt`/`Denom` с полной цепочкой
  гвардов (compiled-tag, arity, vararg, coroutine, hooks, depth,
  stack-cap) + nil-fill результатов + memcpy аргументов.
- **scimark-fft**: ~100% времени в JIT-коде; на каждый табличный
  доступ цепочка гвардов (тег таблицы, метатаблица, интегральность
  ключа ×2, границы, hole-check) + боксинг в 16-байтные `{i32,i64}`
  (`emit_gettable`/`emit_settable`).
- **mandelbrot**: после back-edge числовой провенанс регистров умирает
  (кроме ctrl/limit/step FORLOOP) → tag-checks (`numok/numbad`-цепочки)
  переделываются каждую итерацию.
- Компиляция ORC сама по себе дешёвая (~0.2 с на запуск fft),
  порог OSR 500 срабатывает везде, где есть циклы; частичные
  рерайт-профили были артефактом измерения.

## 3. Механизмы (ранжировано: эффект × шанс обогнать × охват)

### FB1 — Loop-carried numeric SSA / hoisting гвардов (расширение M3.7)

Самый широкий кластер: **mandelbrot, scimark-fft, nbody, nsieve,
fannkuch** (5 тестов). Технически самый дешёвый — не новый механизм,
а распространение существующего loop-SSA (сейчас только для
ctrl/limit/step в `emit_forloop`, `src/jit/compiler.cr:1101`) на все
регистры: факт «R[x] — число», валидный на входе в цикл, протаскивается
через phi на голове, если тело его не убивает. Снимает per-iteration
tag-checks и повторные гварды таблиц.

Шанс обогнать: **mandelbrot и fannkuch (2.0–2.8x) — реальный**.

### FB2 — Инлайнинг горячих Lua-вызовов (M5 из JIT.md)

Самый эффектный: **spectral-norm (19.4x → потенциально 2–3x),
partialsums, series-часть, array3d-часть**. Малые листовые прототипы
(A — 3 инструкции чистой арифметики) инлайнятся в callsite с
identity-гвардом на замыкание + гвардом arity/типов; деопт при
невыполнении. Это аналог call forwarding у LuaJIT.

Вместе с FB2, как минимум:
- **Инлайн GETUPVAL** — тривиально по устройству `UpValue`
  (`src/value.cr:971`: open = `stack`+`idx`, closed = `value`):
  пара загрузок вместо call. Сразу −7% spectral-norm, помогает
  всем замыканиям в циклах.

Шанс обогнать: **partialsums, series — реальный** (нужно ~2x на
числовом цикле).

### FB3 — TFORCALL (generic-for) в JIT + unboxed Float64-массивы

- `TFORCALL` сейчас валят компиляцию всего прототипа
  (`src/jit/compiler.cr:756`) → главный цикл array3d (и любой код с
  `for … in pairs/t:iter()`) интерпретируемый.
- Спекулятивная unboxed array part в `LuaTable`: массив, держащий
  только числа, хранится в отдельном буфере `Float64[]`; появление
  не-числа → репак/деопт. Три выигрыша: вдвое меньше памяти, Boehm
  не сканирует буфер как указатели (array3d: 45% GC!), LLVM получает
  чистые `double[]` load/store и может векторизовать fft.

Полная победа в array3d маловероятна (нужно ~29x против одного
сфузженного трейса LuaJIT); реалистично 3–5x.

### FB4 — Прямой вызов нативных функций из JIT

**series** (`f` = `math.sin`/`cos` — нативные, M5 неприменим), nbody
(`sqrt`). Задел есть: `fast1 : (Float64 -> Float64)?` в
`src/value.cr:1141`. Нужно: inline-cache указателя нативной функции
в callsite (гвард identity) + прямой call, минуя `jit_dispatch_call`
и нативный кадр, где семантика позволяет.

## 4. Что НЕ выиграем (не тратить силы)

- **binary-trees** — allocation-bound: у LuaJIT бамп-аллокация в своем
  GC, у нас Boehm-malloc через хелпер. Обгон = inline-аллокация,
  большое усилие ради одного теста.
- **fasta** — строковая конкатенация + random; выигрыш LuaJIT системный.
- **recursive-fib** — уже паритет (1.793 vs 1.814, ~1.2% — шум min-of-3);
  углублять отрыв можно лишь дешевизной call path, инлайнинг рекурсии
  невозможен.

## 5. Порядок работ

1. **FB1** loop-SSA — cheapest, 5 тестов, старт для всего остального
   (после него чище измеряется вклад FB2–FB4).
2. **GETUPVAL-инлайн** (часы работы, изолированный кусок).
3. **FB2** M5-инлайнинг — spectral-norm/partialsums.
4. **FB4** нативные вызовы — series.
5. **FB3** TFORCALL → потом unboxed-массивы (самый большой кусок,
   трогает `LuaTable` и GC-инварианты).

После каждого шага — `rake benchmark:report` + perf-профиль худших
(методика ниже). Критерий успеха FB1: исчезновение `numok/numbad`-цепочек
из тела цикла в `*-post.ll` (дамп через `LUA5_JIT_DUMP=dir`).

## 6. Методика проверки

```sh
# профиль худшего теста
perf record -g -- bin/lua5 bench/vendor/LuaJIT-test-cleanup/bench/<b>.lua <param>
perf report --stdio --no-children --percent-limit 1

# дамп IR (pre/post оптимизаций)
LUA5_JIT_DUMP=/tmp/jd bin/lua5 … ; ls /tmp/jd/*-post.ll

# трасса tier-up (что скомпилировалось / что bail)
LUA5_JIT=trace bin/lua5 … 2>&1 | grep -E 'compiled|bail'

# только интерпретатор (изоляция вклада JIT)
LUA5_JIT_THRESHOLD=999999999 bin/lua5 …
```

Килл-свитчи для бисекции: `LUA5_JIT_FASTCALL`, `LUA5_JIT_EDGE`,
`LUA5_JIT_PHIMERGE`, `LUA5_JIT_PIPELINE` (`src/jit/compiler.cr:146`).
