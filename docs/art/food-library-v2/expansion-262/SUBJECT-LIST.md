# Issue 262 · proposed subject list (round 1 — STOP for owner review)

Status: **PROPOSED — awaiting owner review; nothing here is approved or produced**  
Base: docs/art/food-library-v2 (schema 2 / library 2.1.0, 13 foods + 4 category fallbacks + neutral, untouched)  
Evidence: public.meal_items, read-only SELECT via Management API, 2026-09-05..2026-09-15, 284 rows / 250 distinct names (raw names stay local, untracked)

Nothing in this document is artwork. No source, master, export, catalog or bundled file was created or
modified. The shipped 18 assets are untouched (see `SHA256SUMS.json` → `shipped_catalog_sha256`).

Grouping: the batch tables below are ordered by production batch (the review unit, ~20–25 identities each);
`category` is a column, and a category-sorted view is derivable from `subjects-proposed.json`. Batch 1
front-loads the rows real logs actually miss; later batches close the ≥100 target with staples.

## Totals

| Scope | Count |
|---|---|
| Shipped food identities (untouched) | 13 |
| Proposed batch 1 — Observed high-frequency + the issue's named gap classes (pork gravy, Chinese kale, linguine) | 24 |
| Proposed batch 2 — Observed 2–4 rows + top everyday Thai staples | 24 |
| Proposed batch 3 — Observed 1 row + Thai/Western staples the app realistically sees | 24 |
| Proposed batch 4 — Zero-row staples that close the ≥100 target (fruit, drinks, Western fast food, sweets) | 23 |
| Proposed batch 5 — Reserve — owner promotes or cuts; not required for ≥100 | 12 |
| Proposed identities, batches 1–4 (required for ≥100) | 95 |
| Proposed identities incl. batch 5 reserve | 107 |
| End state, batches 1–4 + shipped 13 | **108** food identities |
| Proposed labeled category fallbacks (not counted) | 5 |

## Coverage estimate against real logged names

Window: 250 distinct names / 284 rows. The estimate applies a
qualifier-tolerant keyword resolver over the proposal (an approximation of #260 part A, not its contract);
percentages are of distinct names (rows in parentheses). Raw names stay local — the repository is public.

| State | Specific art | Labeled category | Neutral / missing |
|---|---|---|---|
| Today, shipped 18 (qualifier-tolerant) | 10.4% (13.7%) | 6.4% (5.6%) | 83.2% (80.6%) |
| After batch 1 (+ proposed fallbacks) | 55.2% (60.2%) | 8.0% (7.0%) | 0.0% (0.0%) |
| After batch 2 (+ proposed fallbacks) | 80.4% (82.4%) | 8.0% (7.0%) | 0.0% (0.0%) |
| After batch 3 (+ proposed fallbacks) | 90.0% (91.2%) | 8.0% (7.0%) | 0.0% (0.0%) |
| After batch 4 (+ proposed fallbacks) | 92.0% (93.0%) | 8.0% (7.0%) | 0.0% (0.0%) |
| After batch 5 (+ proposed fallbacks) | 92.0% (93.0%) | 8.0% (7.0%) | 0.0% (0.0%) |

Named rows from the issue (already public):

| Logged name | Resolves to | Tier | Batch |
|---|---|---|---|
| `Americano (black, no sugar, homemade)` | `coffee` | existing | — |
| `Pork with brown gravy (moo ob style)` | `braised-pork` | specific | 1 |
| `White rice, cooked (half portion)` | `jasmine-rice` | existing | — |
| `Chinese kale, cooked (kana)` | `stir-fried-greens` | specific | 1 |
| `Pasta (linguine), cooked` | `pasta` | specific | 1 |

Rows per proposed identity (top 15, observed rows in window):

`yogurt` 15, `boiled-egg` 11, `sweet-potato` 9, `berries` 8, `hot-pot` 8, `egg` 7, `sourdough-bread` 7, `cheese` 6, `gravy` 6, `noodle-soup` 6, `sticky-rice` 6, `cereal-flakes` 5, `chili-oil` 5, `ice-cream` 5, `smoothie` 5

## Categories

Existing: `produce`, `grains`, `protein`, `drinks`, `soup`.  
Proposed new: `dairy` — yogurt, cheese, milk — 20+ observed rows with no honest existing category; `sweets` — ice cream, Thai sweets, cake, chocolate — no existing category; `prepared` — composed single-plate dishes (rice bowls, wraps, pizza, sushi) — neither a single ingredient nor a category; `condiments` — dipping sauces, chili oil, gravies, oils — 15+ observed rows; small saucer/cruet studies.  
New categories need a label entry in FoodArtwork.swift categoryLabels (impl lane, #260/#241 follow-up); without it the resolver falls back to the capitalized category id, which is acceptable.

Proposed labeled fallbacks (owner decision, not counted toward 100): `fallback-soup` (category exists with one food and no fallback; pork/blood/clear soups currently drop to neutral), `fallback-dairy` (new category), `fallback-sweets` (new category; also the honest home for toppings/decorations), `fallback-prepared` (new category; shared plates and composite restaurant dishes), `fallback-condiments` (new category).

## Batch 1 — Observed high-frequency + the issue's named gap classes (pork gravy, Chinese kale, linguine) (24)

| # | id | category | name | aliases (incl. Thai) | visual (one line) | evidence |
|---|---|---|---|---|---|---|
| 1 | `sweet-potato` | produce | Sweet potato | soft dried sweet potato, japanese sweet potato, baked sweet potato, มันหวาน, มันหวานญี่ปุ่น, มันเทศ | A split roasted sweet potato with dark skin and golden-orange flesh beside a soft dried slab. | 10 rows (most frequent non-drink item) |
| 2 | `yogurt` | dairy | Yogurt | greek yogurt, plain yogurt, yogurt bowl, โยเกิร์ต, กรีกโยเกิร์ต | A shallow bowl of thick cream yogurt with an uneven spoon-pulled surface and a few dark berry marks. | 13 rows across plain / with cornflakes / with honey / garlicky |
| 3 | `berries` | produce | Berries | blueberries, blackberries, mixed berries, frozen blueberries, บลูเบอร์รี่, เบอร์รี่ | A loose scatter of small dark-blue and black berries with pale bloom highlights and broken ink outlines. | 8 rows |
| 4 | `boiled-egg` | protein | Boiled egg | soft-boiled egg, hard-boiled egg, poached egg, onsen egg, ไข่ต้ม, ไข่ลวก, ไข่ออนเซ็น | A halved boiled egg with a soft warm yolk and a whole peeled egg beside it, cream wash and selective edge ink. | 10 rows (soft-boiled, boiled, poached, onsen, ไข่ต้ม, ไข่ลวก) |
| 5 | `egg` | protein | Egg | eggs, chicken egg, duck egg, whole egg, ไข่, ไข่ไก่, ไข่เป็ด | Two whole eggs in the shell, one pale and one warm-brown, with uneven speckle wash and quiet shadow. | 7 rows written as bare 'Egg' / 'Eggs' / 'Chicken egg' / 'Duck egg' (cooking method unknown — a whole shell egg is the honest sign) |
| 6 | `sticky-rice` | grains | Sticky rice | khao niao, glutinous rice, ข้าวเหนียว | A dense pressed mound of translucent-white sticky rice spilling from a woven bamboo basket lid. | 6 rows |
| 7 | `braised-pork` | protein | Braised pork | pork with brown gravy, moo ob, stewed pork, pork stew, assorted pork, pork belly braised, หมูอบ, หมูตุ๋น, หมูพะโล้ | Thick-cut pork pieces glossed with dark brown gravy pooling on a plate, ochre-brown washes and broken ink. | 3 rows incl. the issue's named gap 'Pork with brown gravy (moo ob style)' |
| 8 | `stir-fried-greens` | produce | Stir-fried greens | chinese kale, kana, kai lan, morning glory, pak boong, sauteed greens, cooked greens, ผัดคะน้า, ผัดผักบุ้ง, คะน้า, ผักบุ้ง | Glossy dark-green stalks and leaves heaped on a plate with oil sheen highlights and sage/forest overlapping washes. | 4 rows incl. the issue's named gap 'Chinese kale, cooked (kana)' |
| 9 | `pasta` | grains | Pasta | linguine, spaghetti, tagliatelle, fettuccine, cooked pasta, พาสต้า, สปาเก็ตตี้ | A nest of long cream pasta strands twisted with a fork, strand ink broken and overlapping, no sauce claim. | 2 rows incl. the issue's named gap 'Pasta (linguine), cooked' |
| 10 | `sourdough-bread` | grains | Sourdough bread | sourdough, sourdough toast, seeded sourdough, whole wheat sourdough, crusty bread, ขนมปังซาวร์โดว์ | A thick open-crumb sourdough slice with a scored blistered crust, ochre crust wash over cream crumb. | 7 rows (existing 'toast' depicts a wholegrain slice; sourdough rows never match it) |
| 11 | `cereal-flakes` | grains | Cereal flakes | cornflakes, corn flakes, granola, breakfast cereal, cereal, คอร์นเฟลก, ซีเรียล | A bowl of golden irregular flakes with milk pooling at the edge, dry-brush flake edges. | 5 rows |
| 12 | `smoothie` | drinks | Smoothie | fruit smoothie, yogurt smoothie, blended fruit, สมูทตี้ | A tall glass of thick blended fruit with a straw, layered orange-to-red wash and a frothy rim. | 5 rows |
| 13 | `cheese` | dairy | Cheese | cheese slices, edam, halloumi, burrata, stracciatella, parmesan, ชีส | A cut wedge of pale cheese and two fanned slices, cream/gold wash and quiet rind line. | 6 rows (slices, edam, burrata ×2, stracciatella, halloumi) |
| 14 | `ice-cream` | sweets | Ice cream | coconut ice cream, gelato, soft serve, blizzard, ไอศกรีม, ไอติม | Two uneven scoops in a small cup with a short spoon, cream and peach washes and melt drips. | 5 rows |
| 15 | `grilled-pork` | protein | Grilled pork | moo yang, grilled pork slices, pork belly grilled, pork neck, kor moo yang, sun-dried pork, หมูย่าง, คอหมูย่าง, หมูแดดเดียว | Sliced grilled pork with charred edges and a fat ribbon, fanned on a plate with irregular grill marks. | 4 rows |
| 16 | `grilled-beef` | protein | Grilled beef | beef steak, steak, seared beef, isaan grilled beef, marbled beef, เนื้อย่าง, สเต็ก | A thick seared beef slab cut to show a rosy interior, dark crust wash and a few red-brown juice marks. | 4 rows |
| 17 | `steamed-fish` | protein | Steamed fish | white fish, cod, seabass, fish fillet, steamed seabass, ปลานึ่ง, ปลากะพง | A pale flaking white fish fillet on a plate with a scatter of scallion and ginger threads. | 4 rows (steamed fish, seabass, cod ×2) |
| 18 | `hot-pot` | soup | Hot pot | shabu, suki, sukiyaki, malatang, hotpot, สุกี้, ชาบู, หม้อไฟ, หมาล่าทัง | A wide pot with simmering broth, ladle, and mixed greens, mushroom and thin meat slices breaking the surface. | 6 rows (malatang ×2, shabu ×2, hot pot vegetables, sukiyaki) |
| 19 | `tom-yum` | soup | Tom yum | tom yum soup, spicy soup, tom yum broth, ต้มยำ, ต้มยำกุ้ง | A bowl of red-orange broth with lemongrass, chili and lime leaf floating, warm red wash and steam marks. | 4 rows (broth ×2, tom yum black soy ×2) |
| 20 | `noodle-soup` | grains | Noodle soup | kuay tiao, boat noodle, rice noodle soup, sen lek, sen yai, yentafo, pho, ก๋วยเตี๋ยว, ก๋วยเตี๋ยวเรือ, เย็นตาโฟ, เส้นเล็ก, เส้นใหญ่ | A bowl of rice noodles in dark broth with chopsticks lifting strands, bean sprout and meat slice marks. | 5 rows (boat noodle ×2, sen lek, sen yai yentafo, ข้าวเปียกเส้น) |
| 21 | `nam-jim` | condiments | Dipping sauce | nam jim, nam jim jaew, jaew, seafood sauce, chili-garlic sauce, ginger soy sauce, dipping sauce, น้ำจิ้ม, น้ำจิ้มแจ่ว, แจ่ว, น้ำจิ้มซีฟู้ด | A small ceramic saucer of red-brown sauce with chili flake specks and a dip streak on the rim. | 5 rows |
| 22 | `wrap` | prepared | Wrap | chicken wrap, shawarma wrap, lamb wrap, tortilla wrap, burrito, แร็พ | A tortilla wrap cut on the diagonal showing greens and filling, cream tortilla with browned press marks. | 4 rows |
| 23 | `chicken-rice` | prepared | Chicken rice | khao man gai, hainanese chicken rice, poached chicken rice, ข้าวมันไก่ | Sliced poached chicken over a mound of oily rice with cucumber and a small saucer, plate viewed from above. | 3 rows; everyday Thai staple |
| 24 | `milk` | dairy | Milk | hot milk, fresh milk, oat milk, almond milk, lactose-free milk, นม, นมสด, นมข้าวโอ๊ต | A tall glass of white milk with an uneven cream wash and a small glass-edge highlight. | 5 rows (hot milk, oat milk ×2, oat-milk cereal, lactose-free milk) |

## Batch 2 — Observed 2–4 rows + top everyday Thai staples (24)

| # | id | category | name | aliases (incl. Thai) | visual (one line) | evidence |
|---|---|---|---|---|---|---|
| 1 | `purple-rice` | grains | Purple rice | riceberry, riceberry rice, black rice, mixed rice, brown rice, multigrain rice, ข้าวไรซ์เบอร์รี่, ข้าวกล้อง | A bowl of dark purple-brown rice grains with a few pale kernels, loose mound above the rim. | 3 rows |
| 2 | `rice-porridge` | grains | Rice porridge | khao tom, jok, congee, โจ๊ก, ข้าวต้ม | A bowl of loose white rice soup with a spoon, ginger threads and a soft-egg mark, watery cream wash. | 2 rows; Thai breakfast staple |
| 3 | `steamed-bun` | grains | Steamed bun | salapao, bao, kaya bun, pork bun, ซาลาเปา | Two plump white steamed buns, one split to show a dark filling, soft cream wash and pleat ink. | 3 rows |
| 4 | `sushi` | prepared | Sushi | nigiri, maki, sushi roll, gunkan, inari, ซูชิ | Two nigiri and three maki pieces on a slate, rice grain marks, a red-orange fish wash and nori band. | 4 rows |
| 5 | `tofu` | protein | Tofu | fried tofu, bean curd, tofu skin, เต้าหู้, เต้าหู้ทอด, ฟองเต้าหู้ | Golden fried tofu cubes and one pale soft block, dry-brush crust over cream interior. | 2 rows |
| 6 | `minced-pork` | protein | Minced pork | ground pork, moo sap, pork mince, bolognese, minced meat, หมูสับ | A crumbly heap of browned minced pork with oil sheen dots, ochre-brown broken wash. | 3 rows |
| 7 | `larb` | prepared | Larb | laab, beef larb, pork larb, koi, ลาบ, ก้อย | A plate of minced meat salad with mint leaves, toasted rice and chili flake marks, herb-green over brown. | 2 rows; Isaan staple |
| 8 | `boiled-pork` | protein | Boiled pork slices | suyuk, bossam, boiled pork, pork belly boiled, หมูต้ม | Pale sliced boiled pork belly fanned on a plate, layered cream-pink wash with a thin fat line. | 3 rows |
| 9 | `poached-chicken` | protein | Poached chicken | shredded chicken, boiled chicken, chicken slices, ไก่ต้ม, ไก่ฉีก | Pale poached chicken sliced and partly shredded, soft cream wash and minimal ink. | 3 rows |
| 10 | `sardines` | protein | Sardines | canned sardines, sardines in oil, tinned fish, ปลาซาร์ดีน, ปลากระป๋อง | An open rectangular tin with three sardines in oil, silver-grey fish wash and a rolled lid. | 2 rows |
| 11 | `cold-cuts` | protein | Cold cuts | mortadella, chorizo, ham, salami, moo yor, sausage slices, หมูยอ, แฮม | Overlapping thin rounds of pink cured meat with fat flecks, one slice folded, on a board. | 3 rows (mortadella, chorizo, หมูยอ) |
| 12 | `dumplings` | prepared | Dumplings | wonton, fried wonton, gyoza, dim sum, เกี๊ยว, เกี๊ยวทอด, เกี๊ยวซ่า | Four pleated dumplings, two pan-browned and two pale steamed, on a small plate with a dip cup. | 2 rows |
| 13 | `meatballs` | protein | Meatballs | fish balls, beef balls, pork balls, meatball skewer, look chin, ลูกชิ้น, ลูกชิ้นปิ้ง | Five round meatballs, three on a bamboo skewer with char marks, cream-brown wash. | 3 rows (fish balls, beef balls, skewer) |
| 14 | `iced-coffee` | drinks | Iced coffee | iced americano, iced black coffee, cold brew, กาแฟเย็น, อเมริกาโน่เย็น | A tall clear cup of dark coffee over ice with a straw, cubes as pale negative shapes. | 2 rows; the existing coffee study is a hot ceramic cup |
| 15 | `matcha-latte` | drinks | Matcha latte | matcha, green tea latte, matcha oat milk, มัทฉะ, มัทฉะลาเต้ | A glass of pale green matcha over milk with a swirl line, sage/leaf wash and a straw. | 2 rows |
| 16 | `soy-milk` | drinks | Soy milk | soymilk, high-protein soy milk, tofusan, น้ำเต้าหู้ | A stout bottle and a small glass of off-white soy milk with a few dark sesame specks. | 3 rows; Thai breakfast staple |
| 17 | `milk-tea` | drinks | Milk tea | thai tea, cha yen, bubble tea, taro milk tea, ชานม, ชาเย็น, ชานมไข่มุก | A tall cup of orange-cream tea with ice and a wide straw, dark pearls settled at the base. | 1 row; Thai everyday drink |
| 18 | `som-tum` | prepared | Som tum | papaya salad, somtum, som tam, ส้มตำ | A mound of shredded pale-green papaya with tomato wedges, long bean and chili marks in a shallow dish. | 1 row + shared Isaan plate; Thai staple |
| 19 | `eggplant` | produce | Eggplant | aubergine, sauteed eggplant, grilled eggplant, มะเขือ, มะเขือยาว | Sautéed eggplant rounds with glossy purple-brown skin and pale soft flesh, oil sheen marks. | 2 rows |
| 20 | `green-salad` | produce | Green salad | mixed salad, mixed leaf salad, side salad, garden salad, สลัด, สลัดผัก | A bowl of loose mixed leaves with a beet slice and almond slivers, leaf/sage overlapping washes. | 2 rows |
| 21 | `chili-oil` | condiments | Chili oil | chili crisp, chili flakes, chili butter, crispy chili topping, fried shallot topping, พริกน้ำมัน, พริกป่น | A small jar of red-orange oil with sunk chili flake sediment and a drizzle spoon. | 5 rows |
| 22 | `gravy` | condiments | Gravy | sauce, brown sauce, peppercorn sauce, creamy sauce, tomato sauce, pan sauce, น้ำเกรวี่, ซอส | A small sauce boat with dark gravy pouring a short arc, brown wash and a spoon rest. | 7 rows (peppercorn, creamy, oyakodon sauce, tomato & pepper, onion dashi, miso, stew gravy) |
| 23 | `thai-sweets` | sweets | Thai sweets | khanom thai, khanom thuay, man nup, coconut cups, khanom, ขนมไทย, ขนมถ้วย | Three small ceramic cups of layered coconut custard and one chewy dark taro piece, cream/peach wash. | 4 rows |
| 24 | `curry` | soup | Curry | thai curry, panang, red curry, massaman, coconut curry, แกง, พะแนง, แกงเผ็ด, มัสมั่น | A bowl of red-orange coconut curry with meat pieces and basil leaf marks, oil sheen ring at the rim. | 1 row (panang beef, written in Thai); core Thai staple |

## Batch 3 — Observed 1 row + Thai/Western staples the app realistically sees (24)

| # | id | category | name | aliases (incl. Thai) | visual (one line) | evidence |
|---|---|---|---|---|---|---|
| 1 | `fried-rice` | prepared | Fried rice | khao pad, egg fried rice, ข้าวผัด | A plate of golden fried rice with egg and scallion flecks, a cucumber slice and lime wedge at the edge. | 0 rows in window; universal Thai staple |
| 2 | `basil-stir-fry` | prepared | Basil stir-fry | pad kra pao, krapow, holy basil stir-fry, ผัดกะเพรา, กะเพรา | Dark minced meat and basil leaves over rice with a crisp fried egg on top, forest-green leaf marks. | 0 rows; the most common Thai one-plate dish |
| 3 | `omelette` | protein | Omelette | thai omelette, kai jeow, scrambled eggs, ไข่เจียว, ไข่คน | A puffed golden Thai omelette folded on a plate with browned lace edges, gold/ochre wash. | 0 rows; Thai staple |
| 4 | `fried-chicken` | protein | Fried chicken | gai tod, crispy chicken, karaage, ไก่ทอด | Two craggy golden fried chicken pieces with dry-brush crust, one drumstick, one thigh. | 0 rows; Thai/Western staple |
| 5 | `pizza-slice` | prepared | Pizza slice | pizza, square pizza slice, พิซซ่า | One triangular pizza slice with a browned crust edge, tomato-red wash and pale cheese pulls. | 2 rows |
| 6 | `sandwich` | prepared | Sandwich | focaccia sandwich, baguette sandwich, toastie, แซนด์วิช | A cut sandwich showing layered filling between two bread halves, cream crumb and greens marks. | 2 rows |
| 7 | `focaccia` | grains | Focaccia | focaccia bread, flatbread, โฟกัชชา | A dimpled rectangular focaccia square with rosemary and salt marks, oil-glossed ochre top. | 1 row (+1 sandwich) |
| 8 | `instant-noodles` | grains | Instant noodles | mama, mama noodles, ramyeon, cup noodles, มาม่า, บะหมี่กึ่งสำเร็จรูป | A bowl of wavy yellow noodles with a soft egg and scallion marks, chopsticks resting on the rim. | 1 row; Thai staple |
| 9 | `roti` | grains | Roti | roti canai, thai roti, โรตี | A folded flaky roti with blistered golden layers and a drizzle line, ochre/cream wash. | 1 row |
| 10 | `mashed-potato` | produce | Mashed potato | mash, potatoes, potato, มันบด, มันฝรั่ง | A soft heap of pale mashed potato with a butter pool and gravy pour, cream/gold wash. | 2 rows |
| 11 | `cooking-oil` | condiments | Cooking oil | olive oil, extra virgin olive oil, oil, น้ำมัน, น้ำมันมะกอก | A slim glass cruet of golden oil with a pour spout and a single oil drop, gold wash. | 4 rows |
| 12 | `raw-vegetable-plate` | produce | Raw vegetable plate | fresh vegetables, raw vegetables, crudites, vegetable sticks, ผักสด | Cucumber batons, long beans and a cabbage wedge fanned on a plate, leaf/sage washes. | 2 rows |
| 13 | `mixed-nuts` | protein | Mixed nuts | nuts, almonds, sliced almonds, cashews, nut butter, ถั่ว, อัลมอนด์ | A small scatter of almonds, cashews and a walnut half, warm ochre/brown washes. | 2 rows |
| 14 | `shabu-slices` | protein | Thin-sliced meat | shabu beef, shabu pork, hotpot meat, sliced beef, thin sliced, เนื้อสไลด์, หมูสไลด์ | Rolled thin raw meat slices fanned on a plate, red/pink marbled wash with pale fat lines. | 3 rows |
| 15 | `beef-rice-bowl` | prepared | Beef rice bowl | gyudon, bibimbap, beef bowl, donburi, ข้าวหน้าเนื้อ | A bowl of rice topped with thin simmered beef and onion, pickled ginger mark, viewed at an angle. | 3 rows |
| 16 | `protein-shake` | drinks | Protein shake | protein milk, protein drink, chocolate protein shake, โปรตีนเชค | A shaker bottle with a mixing ball and a dark chocolate-brown drink line, mono-line bottle geometry. | 2 rows |
| 17 | `apple` | produce | Apple | red apple, green apple, แอปเปิ้ล | A whole red apple beside a cut quarter with dark seeds, uneven red/gold wash. | 0 standalone rows; universal staple |
| 18 | `pomelo` | produce | Pomelo | pomelo segments, grapefruit, ส้มโอ | Peeled pale-pink pomelo segments beside a thick-rind wedge, peach/cream wash. | 1 row |
| 19 | `cucumber` | produce | Cucumber | cucumber slices, แตงกวา | A cucumber with three cut rounds, dark green skin wash and pale seeded centres. | 1 row |
| 20 | `kimchi` | produce | Kimchi | banchan, korean side dishes, pickled vegetables, กิมจิ | A small bowl of red-stained cabbage leaves with chili fleck marks, red/sage wash. | 1 row (Korean side dishes) |
| 21 | `mushrooms` | produce | Mushrooms | shiitake, enoki, button mushrooms, เห็ด | Three shiitake caps and a small enoki bundle, brown/cream dry-brush caps. | 0 standalone rows; frequent component |
| 22 | `shrimp` | protein | Shrimp | prawns, grilled shrimp, กุ้ง, กุ้งย่าง | Two curled cooked shrimp with orange-red banded shells and a lime wedge. | 0 rows; Thai staple |
| 23 | `stewed-duck` | protein | Stewed duck | duck, roast duck, braised duck, ped palo, เป็ด, เป็ดพะโล้, เป็ดย่าง | Sliced dark-glazed duck with crisp skin edge on a plate, deep brown wash and a star anise mark. | 1 row |
| 24 | `cake` | sweets | Cake | slice of cake, cheesecake, coffee cake, brownie, เค้ก | A single triangular cake slice with two sponge layers and cream filling on a small plate. | 0 rows; needed so 'coffee cake' has an honest home (matcher negative case in #260) |

## Batch 4 — Zero-row staples that close the ≥100 target (fruit, drinks, Western fast food, sweets) (23)

| # | id | category | name | aliases (incl. Thai) | visual (one line) | evidence |
|---|---|---|---|---|---|---|
| 1 | `tea` | drinks | Tea | hot tea, green tea, black tea, herbal tea, ชา, ชาเขียว, ชาร้อน | A ceramic cup of amber tea with a tag string over the rim, gold wash and steam marks. | 0 rows; universal |
| 2 | `latte` | drinks | Latte | cafe latte, cappuccino, flat white, milk coffee, ลาเต้, กาแฟนม | A wide cup of milk coffee with a leaf pour mark, cream/brown wash — distinct from the black-coffee study. | 0 rows; universal |
| 3 | `orange-juice` | drinks | Orange juice | juice, fruit juice, น้ำส้ม, น้ำผลไม้ | A short glass of orange juice with a pulp line and an orange half beside it. | 0 rows; universal |
| 4 | `coconut-water` | drinks | Coconut water | young coconut, coconut juice, น้ำมะพร้าว | A trimmed young coconut with a straw and a splash of pale water, cream/sage wash. | 0 rows; Thai staple |
| 5 | `beer` | drinks | Beer | lager, draft beer, เบียร์ | A tall pint glass of golden beer with an uneven foam head, gold wash and condensation marks. | 0 rows; owner may cut |
| 6 | `watermelon` | produce | Watermelon | แตงโม | A red watermelon wedge with black seed marks and a green rind band. | 0 rows; Thai fruit staple |
| 7 | `pineapple` | produce | Pineapple | สับปะรด | Cut pineapple spears beside a wedge with rind, gold wash and eye marks. | 0 standalone rows (smoothie ingredient); Thai fruit staple |
| 8 | `papaya` | produce | Papaya | ripe papaya, มะละกอ | A halved ripe papaya with orange flesh and a cluster of dark seeds. | 0 rows; Thai fruit staple |
| 9 | `dragon-fruit` | produce | Dragon fruit | pitaya, แก้วมังกร | A halved dragon fruit with white speckled flesh and pink leafy skin. | 0 standalone rows; Thai fruit staple |
| 10 | `guava` | produce | Guava | ฝรั่ง | A whole green guava and a wedge showing pale flesh and seed band. | 0 standalone rows; Thai fruit staple |
| 11 | `grapes` | produce | Grapes | องุ่น | A small bunch of dark grapes with bloom highlights and a stem line. | 0 rows; universal |
| 12 | `strawberry` | produce | Strawberries | strawberries, สตรอว์เบอร์รี่ | Three strawberries, one halved, red wash with seed specks and leaf caps. | 0 rows; universal |
| 13 | `tomato` | produce | Tomato | cherry tomatoes, tomatoes, มะเขือเทศ | A whole tomato and a cut half showing seed chambers, red wash and calyx ink. | 0 standalone rows; frequent component |
| 14 | `corn` | produce | Corn | sweet corn, corn kernels, corn on the cob, ข้าวโพด | A corn cob with husk pulled back and a spill of loose kernels, gold wash. | 1 row |
| 15 | `french-fries` | prepared | French fries | fries, chips, เฟรนช์ฟรายส์ | A paper sleeve of golden fries at uneven heights, dry-brush crisp edges. | 0 rows; universal |
| 16 | `burger` | prepared | Burger | hamburger, cheeseburger, เบอร์เกอร์ | A stacked burger with a sesame bun, patty, cheese drip and lettuce edge. | 0 rows; universal |
| 17 | `spring-roll` | prepared | Spring rolls | fried spring roll, fresh spring roll, ปอเปี๊ยะ, ปอเปี๊ยะทอด | Three golden fried spring rolls, one cut to show filling, with a small dip cup. | 0 rows; Thai staple |
| 18 | `satay` | protein | Satay | moo ping, pork skewer, chicken satay, grilled skewer, หมูปิ้ง, สะเต๊ะ | Three charred meat skewers fanned on a plate with a small peanut sauce cup. | 0 rows; Thai street staple |
| 19 | `mango-sticky-rice` | sweets | Mango sticky rice | khao niao mamuang, ข้าวเหนียวมะม่วง | Sliced golden mango beside a coconut-glossed sticky rice mound with a mung bean sprinkle. | 0 rows; Thai dessert staple |
| 20 | `chocolate` | sweets | Chocolate | chocolate bar, dark chocolate, chocolate topping, ช็อกโกแลต | Two broken squares of a dark chocolate bar with a scored top, deep brown wash. | 2 rows (decorations/toppers) |
| 21 | `cookie` | sweets | Cookie | biscuit, cracker, cereal cracker, คุกกี้, บิสกิต | Two round cookies, one bitten, with chip marks and a cracked surface, ochre wash. | 1 row (cereal cracker) |
| 22 | `oatmeal` | grains | Oatmeal | oats, overnight oats, porridge oats, chia pudding, overnight chia, ข้าวโอ๊ต | A jar of layered oats with a berry top and a spoon, cream wash and grain marks. | 1 row (overnight chia) |
| 23 | `miso-soup` | soup | Miso soup | miso, japanese soup, ซุปมิโซะ | A dark lacquer bowl of cloudy miso with tofu cubes and wakame threads. | 0 rows (miso paste 1); staple |

## Batch 5 — Reserve — owner promotes or cuts; not required for ≥100 (12)

| # | id | category | name | aliases (incl. Thai) | visual (one line) | evidence |
|---|---|---|---|---|---|---|
| 1 | `pancake` | grains | Pancakes | pancakes, hotcakes, แพนเค้ก | A short stack of three pancakes with a butter square and a syrup drip. | 0 rows; reserve |
| 2 | `croissant` | grains | Croissant | pastry, ครัวซองต์ | A single flaky croissant with layered crescent ink and a golden dry-brush top. | 0 rows; reserve |
| 3 | `bacon` | protein | Bacon | streaky bacon, เบคอน | Three wavy bacon rashers with red-brown meat bands and pale fat ribbons. | 0 rows; reserve |
| 4 | `sausage` | protein | Sausage | sausages, hot dog, ไส้กรอก | Two browned link sausages with a knife score and a small mustard dab. | 0 rows; reserve |
| 5 | `peanuts` | protein | Peanuts | roasted peanuts, peanut butter, ถั่วลิสง | A small heap of shelled peanuts with two in shell, ochre/brown wash. | 0 rows; reserve |
| 6 | `ramen` | grains | Ramen | ramen bowl, tonkotsu, ราเมง | A deep bowl of wavy noodles in pale broth with a halved egg, chashu slice and nori. | 0 rows; reserve (noodle-soup covers Thai bowls) |
| 7 | `donut` | sweets | Donut | doughnut, โดนัท | A ring donut with a glossy glaze wash and a bite taken out. | 0 rows; reserve |
| 8 | `chicken-wings` | protein | Chicken wings | wings, buffalo wings, ปีกไก่ | Three glazed chicken wings with char marks and a celery stick. | 0 rows; reserve |
| 9 | `grilled-squid` | protein | Grilled squid | squid, calamari, ปลาหมึกย่าง, ปลาหมึก | A scored grilled squid tube with tentacles, char marks and a lime wedge. | 1 row (ika nigiri is sushi); reserve |
| 10 | `khanom-jeen` | grains | Khanom jeen | thai rice vermicelli, rice vermicelli, ขนมจีน | Coiled nests of thin white rice noodles on a plate with a curry pour and herb marks. | 0 rows; reserve |
| 11 | `pad-thai` | prepared | Pad thai | phat thai, ผัดไทย | Orange-tinted flat noodles with shrimp, bean sprouts, a lime wedge and crushed peanut marks. | 0 rows; reserve — alternatively an alias on the existing stir-fried-noodles study |
| 12 | `boba-tea` | drinks | Boba tea | boba, pearl milk tea, ชาไข่มุก | A domed-lid cup with dark tapioca pearls and a wide straw, cream/brown wash. | 0 rows; reserve — milk-tea already carries 'bubble tea' as an alias; only split if the owner wants a pearl-specific study |

## Intentionally not illustrated (category fallback or neutral by design)

| Class | Examples (public/generic) | Resolves to | Why |
|---|---|---|---|
| Shared / composite restaurant plates | a quarter share of an Isaan spread; a Korean banchan side-dish set; a fish-ball / fish-tofu / dumpling assortment | fallback-prepared (proposed) else neutral | no single honest subject; the neutral/prepared sign is the truthful mark |
| Toppings, garnishes and decorations | chocolate wafer decoration; fried garlic or shallot garnish; grilled vegetable topping | chili-oil / chocolate / category fallback | sub-item of another row; a dedicated study would out-weigh the food it garnishes |
| Branded packaged products | branded cereal cracker pack; branded lactose-free protein milk; branded high-protein soy milk | generic study (cookie, protein-shake, soy-milk) | no brand marks, packaging or logos in the library; generic form only |
| Pure cooking inputs written as items | cooking oil used for eggs; olive oil in a sauce; miso paste | cooking-oil / gravy | one generic cruet/saucer study; no per-ingredient art |
| Specific cuts, breeds, offal and blood dishes | boiled pork with offal; pork skin/ear salad; pork blood soup | boiled-pork / fallback-protein / fallback-soup | the library never claims a cut or organ; generic protein/soup marks only |
| Water | — | n/a | water is logged through water_logs, not meal_items |

## Coordination with #260 (alias vocabulary)

`alias-proposals-260.json` lists, per proposed identity, the aliases the catalog would carry and the
descriptive-name fragments the matcher must tolerate. Two shipped-asset alias additions are proposed and
recorded there for the orchestrator to sequence (the impl lane must not edit the catalog):

- `toast` + `thick toast`, `sourdough-style toast` — observed thick sourdough-style toast rows; the study depicts a toasted slice
- `vegetable-soup` + `radish soup`, `clear vegetable soup` — observed 'Radish soup' row; the study is a clear vegetable broth

Negative cases preserved: `coffee cake` → proposed `cake` (never `coffee`); mixed/shared plates → `fallback-prepared` or neutral.

## Production plan (after owner approval of this list)

Per batch (~20–25 identities): tokenized source SVG per identity (256×256, `<!-- WASH_DEFS -->`, locked palette);
Paper + Night masters; 64/192/512 RGBA exports per theme; `subjects.json` + `catalog.json` entries via
`ink_add.py`; `SHA256SUMS.json` / `build-cache.json` updated; clean rebuild hash proof; shipped-18 byte-identity
proof by hash; Paper/Night contact sheets, labeled phone proofs and the 64 px placement check; then **STOP**
for owner review. Release-gate acceptance set, proof cohorts and library version are re-pinned per batch
(the current gate rejects a 19th entry by design; the batch amends its acceptance set explicitly).

## Owner decisions requested

1. Approve / cut / rename identities per batch (batch 5 is reserve).
2. Accept the four new categories (`dairy`, `sweets`, `prepared`, `condiments`) and the five labeled fallbacks.
3. Confirm the `egg` (whole shell) vs `boiled-egg` split and `pasta` as one long-strand study.
4. Confirm batch 1 as the first production batch.

Reproduce: `PYTHONDONTWRITEBYTECODE=1 python3 skills/food-art/scripts/ink_expansion_plan.py render` then `check`.

