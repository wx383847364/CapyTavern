# 数值源（design/balance）

> 状态：正式 v0.2（2026-11-06 按 P2a 实测重调，待测试复核）。六张表数值齐全，无 `null`。
> 写权：只由策划写。`client/data/balance/` 里的副本由程序同步，同步时把差异报制作人；程序不手改本目录。
> 依据：`doc/裁决.md` 2026-11-06 的配表字段清单、数值源写权、P2a 打回三条。字段名与客户端配置一致。
> v0.2 相对 v0.1 只改了 `global.json` 的 `party_scaling`（见下「P2a 重测」），其余表没动。

## 文件

| 文件 | 内容 |
|---|---|
| `global.json` | 表 4 全局：tick、时限、公共间隔、暴击、`party_scaling`、`defense_formula`、`wave` |
| `classes.json` | 表 1 职业：4 行，含 `armor`、`magic_resist`（可选，缺省 0） |
| `skills.json` | 表 2 技能：16 行，伤害类带 `school` |
| `enemies.json` | 表 3 敌人：3 行，含 `school`、`armor`、`magic_resist` |
| `modifiers.json` | 表 5 天赋与两件套修正：天赋 8 个（15 行）+ 两件套 4 行 |
| `items.json` | 表 6 物品：40 件（32 初始 + 8 奖励），不含装备属性 |

## 计算口径

- 目标：四人满编、正常操作，约 60～80 秒打赢；四人完全不操作输；一次操作失误不团灭。
- 先按目标定敌人总血量，再倒推各职业单位时间输出与技能数值，不套旧 V2 系数。
- 防护：`减伤比例 = 防护 ÷ (防护 + K)`，K=100，物理吃 `armor`，魔法吃 `magic_resist`。
- 伤害与治疗：加成同类加算，全部算完后只在最后四舍五入取整，最小为 1。
- 消耗：四舍五入取整。时间：保留 0.1 秒；战斗 tick 仍是 0.05 秒。
- 治疗：`amount` 是治疗量，`effective` 是实际补上的量，仇恨只按 `effective`。
- 修正：`add_pct` 同类加算；`add_flat` 只给持续时间秒数（七天稿「增加 2 秒」「增加 1 秒」是绝对值）。切换天赋时从基础值重算，不叠层。
- 表 5 只改现有技能的数值或持续时间，不增删技能槽、不改目标类型。

## 交付范围与口径说明

- **面板值与有效值**：表里是面板值（防护前）。战斗结算按 `defense_formula` 对每次伤害实时算防护。v0.1 我是把防护折进有效值估算的，两者不等价，所以**所有数字以 P2a 实测为准**，不再声称折算结果等于实测。
- **普攻的 `school`**：不单设字段，按职业默认：战士、盗贼物理，法师魔法，牧师为治疗不吃防护。
- **基线**：数值按「初始 8 件装备已含在职业面板」「默认天赋 t1」「无两件套」调。装备属性表不进 P2，天赋 t2 与两件套只作增量检查。
- **仇恨**：战士 `threat_coef` 取 3.0，保证敌人优先打战士；挑衅只在抢回目标时用。
- **不属于本表**：`arena`、`ally_spawn`、`unit_radius` 这些站位与尺寸字段归程序，同步时保留程序自有文件里的原值。`wave` 的 x、y 沿用 P1 站位。
- **`add_flat`、`party_scaling`**：制作人已认可（`doc/裁决.md`）。

## P2a 重测（实测，bot 操作）

**复跑命令**（测试按同命令复核；要求 `client/data/balance/` 与本目录逐字节一致，否则先同步）：

```
godot --headless --path client --script res://scripts/tests/balance_sweep.gd -- --seeds=40
godot --headless --path client --script res://scripts/tests/balance_sweep.gd -- --seeds=100 --only=1auto
godot --headless --path client --script res://scripts/tests/balance_sweep.gd -- --seeds=40 --only=4auto --talent=t2
godot --headless --path client --script res://scripts/tests/balance_sweep.gd -- --seeds=40 --only=4auto --sets=warrior,rogue,mage,priest
```

种子范围：从 1 起连续 N 个（`--seeds=40` 即 1～40）。导出包可用 `CapyTavern --headless -- --battle=N --autoplay --fast --seed=1..40` 对应复核；1 人是 `--battle=1`，2、3 人要加 `--classes=warrior,,,priest`、`--classes=warrior,mage,,priest`。

**v0.2 实测**（`--seeds=40`）：

| 场景 | 胜率 | 胜局中位 | 败局中位 | 目标 |
|---|---|---|---|---|
| 4 人 自动操作 | 100% | 72.4 秒 | - | 60～80 秒打赢 |
| 4 人 不操作 | 0% | - | 44.6 秒 | 必输 |
| 4 人 牧师治疗置 0 | 0% | - | 80.1 秒 | 牧师不可省 |
| 3 人（战、法、牧） | 100% | 76.9 秒 | - | 稳赢 |
| 2 人（战、牧） | 100% | 79.8 秒 | - | 稳赢 |
| 1 人（战） | 55%（100 个种子为 58%） | 78.6 秒 | 77.7 秒 | 胜率 30%～60% |
| 1 人 不操作 | 0% | - | 50.0 秒 | 必输 |

- 4 人天赋全部取 t2：100%、71.5 秒；全两件套：100%、72.3 秒。8 个天赋没有一个让 4 人胜率下降，用时差不到 1 秒。
- 1 人战士取 t2（`战备`）：5%。单人时战士 t1 `坚壁` 明显更强，因为 1 人没有牧师，减伤时间更值钱。这是已知取舍，4 人队里不显现。
- 一次精英「震地」全员都在圈内时约 330 点有效伤害（按 100 物理伤害、四人防护算出），约为全队血量的 20%，不会一下团灭。

**v0.1 → v0.2 的差异与原因**

| 字段 | v0.1 | v0.2 | 原因 |
|---|---|---|---|
| `party_scaling["1"].hp / dmg` | 0.32 / 0.37 | 0.321 / 0.331 | 1 人实测 0%，要进 30%～60% |
| `party_scaling["2"].hp` | 0.38 | 0.34 | 2 人 90.6 秒偏长，压到约 80 秒，留出 120 秒上限的余量 |
| `party_scaling["3"].hp` | 0.75 | 0.65 | 3 人 88.1 秒偏长，压到约 77 秒 |

- v0.1 里「1 人约 40%」是我用折算后的 Python 模型估的，没有在 Godot 上复现，作废。
- **1 人在悬崖边上**：`dmg` 0.331～0.332 是 55%～58%，0.333 就掉到约 27%，0.35 起 0%；`hp` 同理。原因是单人只有战士，扛不扛得住一次震地加施法怪的组合几乎决定胜负，数值对取整很敏感。真人操作会比 bot 灵活，不应以这一项为准；它只保证「1 人能赢也会输」。
- 4 人 72.4 秒比 v0.1 估的 67 秒慢约 8%，在 60～80 秒目标内，接受，不回表。
- 伤害占比、承伤比例这类 v0.1 的估算数，没有在 Godot 上复核，已删除。

**这是机器人操作的结果，不是真人试玩。** 真人结论要等测试和 human 试玩，数值再据此调。盗贼打断在 bot 里每场约 1 次，打断收益要靠真人检验。

## 物品表（items.json）

- 字段：`id, name, slot, class_id, source, set_id`；`_slots`、`_sets` 是给界面和校验用的说明，程序可读可不读。
- `slot` 取 `weapon, helmet, chest, shoulder, legs, boots, ring, amulet`，依次是武器、头盔、胸甲、肩膀、裤子、鞋子、戒指、护符。存档 `equips` 的八槽用同一组 id。
- `source`：`initial`（32 件，四职业各八槽）、`reward`（8 件，四职业各一件肩膀、一件鞋子）。招募发放并穿戴的是该职业的 `initial` 八件。
- `set_id` 只给 `reward` 件，形如 `warrior_set`；同职业的肩膀和鞋子同一个 `set_id`。
- **两件套生效**：同一 `set_id` 的两件都穿上，才启用 `modifiers.json` 里 `group=set` 且 `class_id` 相同的行。set 行按 `class_id` 对应，不另加字段。
- 初始肩膀和鞋子也各有一件，奖励件是替换候选，不会同时再发初始件。物品只能被同 `class_id` 的英雄穿戴。
- id 规则：初始件 `{class_id}_{slot}`，奖励件 `{class_id}_{slot}_set`。
