/* Проект «Секреты Тёмнолесья»
 * Цель проекта: изучить влияние характеристик игроков и их игровых персонажей 
 * на покупку внутриигровой валюты «райские лепестки», а также оценить 
 * активность игроков при совершении внутриигровых покупок
 * 
 * Автор: Холкин Егор
 * Дата:  18.01.2025
*/

-- Часть 1. Исследовательский анализ данных
-- Задача 1. Исследование доли платящих игроков

-- 1.1. Доля платящих пользователей по всем данным:
SELECT 	
	COUNT(id) AS players_amount,
	(SELECT SUM(payer) FROM fantasy.users WHERE payer = '1') AS donaters_amount,
	AVG(payer) AS donaters_part
FROM   fantasy.users;

-- 1.2. Доля платящих пользователей в разрезе расы персонажа:
SELECT		
			DISTINCT race,
			COUNT(id) OVER(PARTITION BY race) AS players_amount,
			donaters_amount,
			ROUND(donaters_amount::numeric / COUNT(id) OVER(PARTITION BY race), 3)
FROM		fantasy.race r
LEFT JOIN   fantasy.users u USING (race_id)
LEFT JOIN   (
			SELECT
			DISTINCT race,
			COUNT(id) OVER(PARTITION BY race) AS donaters_amount
			FROM		fantasy.race r
			LEFT JOIN   fantasy.users u USING (race_id)
			WHERE       payer = '1'
			) AS podzapros USING (race);
-- Задача 2. Исследование внутриигровых покупок
-- 2.1. Статистические показатели по полю amount:
SELECT 
	COUNT(*), --
	SUM(amount),
	MIN(amount),
	MAX(amount),
	AVG(amount),
	ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY amount)::numeric, 2) AS median,
	ROUND(STDDEV(amount)::numeric, 2) AS sigma
FROM   fantasy.events;
-- 2.2: Аномальные нулевые покупки:
SELECT  COUNT(*)
FROM    fantasy.events
WHERE   amount = '0'
UNION ALL -- здесь я проверил на всякий случай, нет ли значений с НУЛЛом
SELECT  COUNT(*)
FROM    fantasy.events
WHERE   amount IS NULL;

SELECT  COUNT(*) / (SELECT COUNT(*) FROM fantasy.events)::NUMERIC
FROM    fantasy.events e
WHERE   amount = '0';
-- 2.3: Сравнительный анализ активности платящих и неплатящих игроков:
WITH total AS(
SELECT
	payer,
	COUNT(DISTINCT id) AS player_amount,
	COUNT(DISTINCT transaction_id) AS buy_count,
	SUM(amount) AS buy_total_amount
FROM		fantasy.users u
LEFT JOIN   fantasy.events e USING (id)
WHERE       amount > 0
GROUP BY    payer
)
SELECT
	CASE
		WHEN  payer = '1'
		THEN  'Платящие'
		ELSE  'Неплатящие'
	END AS    "Игроки",
	player_amount AS "Количество игроков",
	buy_count / player_amount AS "Среднее количество покупок",
	ROUND(buy_total_amount / player_amount::NUMERIC) AS "Средние сумм. затраты на игрока"
FROM total;
-- 2.4: Популярные эпические предметы:
WITH total_sell AS(
SELECT
	game_items,
	COUNT(transaction_id) AS total_amount,
	COUNT(DISTINCT e.id) AS unique_buyers
FROM      fantasy.items i 
LEFT JOIN fantasy.events e USING (item_code)
WHERE     e.amount > 0 OR e.amount IS NULL
GROUP BY  game_items
),
prodazhi AS (
SELECT
	game_items,
	total_amount AS "Количество продаж",
	total_amount / SUM(total_amount) OVER() AS "Доля продаж",
	unique_buyers AS "Уникальных покупателей",
	unique_buyers::numeric / (SELECT COUNT(DISTINCT id) FROM fantasy.users u) AS "Доля покупателей"
FROM  total_sell t
GROUP BY game_items, total_amount, unique_buyers
)
SELECT *
FROM prodazhi
ORDER BY "Количество продаж" DESC;
-- Часть 2. Решение ad hoc-задач
-- Задача 1. Зависимость активности игроков от расы персонажа:
-- Привет, спасибо за подробный ревью
-- Очень крутая штука с FILTER, жаль не проходили на курсе, очень бы упростило жизнь, если бы знал про неё)


WITH unique_players AS (
SELECT 
	DISTINCT r.race_id,
    COUNT(DISTINCT u.id) AS unique_player_count
FROM fantasy.users u
RIGHT JOIN fantasy.race r USING (race_id)
GROUP BY race_id
),
buyers AS (     -- здесь изначально неправильно понял условие задачи. Подправил ошибку, перенеся вычисление непосредственно доли в конец запроса, 
				-- т.к. подзапрос в селекте разрешает выводить только 1 строку
SELECT
	race_id,
	COUNT(DISTINCT e.id) AS buyers_count
FROM fantasy.users u 
LEFT JOIN fantasy.events e USING (id)
WHERE amount > 0
GROUP BY race_id
),
donaters AS (   -- сделал несколько иначе, чем в ревью, но ошибку исправил, спасибо
SELECT 
	race_id,
	ROUND(buying_payers_count/buyers_count::NUMERIC, 3) AS payers_share
FROM 
	(
	SELECT
		race_id,
		COUNT(DISTINCT e.id) AS buying_payers_count
	FROM fantasy.users u
	LEFT JOIN fantasy.events e USING (id)
	WHERE payer = '1' AND amount > 0
	GROUP BY race_id) AS podzapros
JOIN buyers USING (race_id)
GROUP BY race_id, buying_payers_count, buyers_count
),
average AS(
SELECT
	race_id,
	ROUND(buy_count/buyers_count_2::NUMERIC) AS avg_buy,
	ROUND(buy_amount/buy_count::NUMERIC) AS avg_amount,
	ROUND(buy_amount/buyers_count_2::numeric) AS avg_sum_amount
FROM(
	SELECT 
		race_id,
		COUNT(transaction_id) AS buy_count,
		SUM(amount) AS buy_amount,
		COUNT(DISTINCT e.id) AS buyers_count_2
	FROM fantasy.events e
	RIGHT JOIN fantasy.users u USING (id)
	WHERE amount > 0
	GROUP BY race_id
	) AS podzapros2
GROUP BY race_id, buy_count, buyers_count_2, buy_amount
)
SELECT 
	race AS "Раса",
	unique_player_count AS "Всего игроков",
	buyers_count AS "Покупающие игроки",
	ROUND(buyers_count / unique_player_count::NUMERIC, 3) AS "Доля покупающих",
	payers_share AS "Доля платящих от покупающих",
	avg_buy AS "Среднее кол-во покупок",
	avg_amount AS "Ср. стоим-ть покупки",
	avg_sum_amount AS "Средняя сумм. всех покупок"
FROM 
	unique_players up
JOIN 
	buyers USING (race_id)
JOIN
	donaters USING (race_id)
JOIN 
	average USING (race_id)
JOIN
	fantasy.race USING (race_id)
ORDER BY "Покупающие игроки" DESC;

-- Задача 2: Частота покупок
-- сначала сделал выборку покупателей, согласно условиям маркетологов

WITH buyers AS (
SELECT 
    u.id AS buyer_id,
    COUNT(e.id) AS buy_count
FROM 
    fantasy.users u
LEFT JOIN 
    fantasy.events e ON u.id = e.id
WHERE amount > 0
GROUP BY u.id
HAVING   COUNT(e.id) >= 25
), -- далее уже, отталкиваясь от выборки покупателей, пошла цепочка CTE
buy_interval_days AS (
SELECT
	buyer_id,
	buy_date,
	prev_buy_date,
	buy_date - prev_buy_date AS buy_interval
FROM (
	SELECT 
	    buyer_id,
	    date::date AS buy_date,
	    LAG(date::date) OVER(PARTITION BY buyer_id ORDER BY date::date) AS prev_buy_date
	FROM 
	    buyers
	JOIN 
	    fantasy.events e ON buyer_id = e.id
	  ) AS bd
),
avg_buy_int AS (
SELECT
	buyer_id,
	ROUND(AVG(buy_interval)) AS avg_buy_interval
FROM buy_interval_days
GROUP BY buyer_id
),
frequency AS (
SELECT
	buyer_id,
	payer AS is_payer,
	avg_buy_interval,
	NTILE(3) OVER(ORDER BY avg_buy_interval DESC) AS buy_freq
FROM avg_buy_int abi
JOIN fantasy.users u ON abi.buyer_id = u.id
),
classification AS (
SELECT 
	buyer_id,
	is_payer,
	avg_buy_interval,
	CASE
		WHEN buy_freq = 1
		THEN 'низкая частота'
		WHEN buy_freq = 2
		THEN 'умеренная частота'
		ELSE 'высокая частота'
	END AS   freq
FROM frequency
ORDER BY avg_buy_interval DESC
),
buyers_analysis AS (
SELECT
	freq,
	COUNT(buyer_id) AS count_buyers
FROM classification
GROUP BY freq),
payers_analysis AS (
SELECT
	freq,
	COUNT(buyer_id) AS count_payers
FROM classification
WHERE is_payer = '1'
GROUP BY freq),
payers_share_analysis AS(
SELECT 
	freq,
	count_buyers,
	count_payers,
	ROUND(count_payers / count_buyers::NUMERIC, 3) AS payers_share
FROM buyers_analysis
JOIN payers_analysis USING (freq)
GROUP BY freq, count_buyers, count_payers
)
SELECT
	freq AS "Частота",
	count_buyers AS "Покупатели",
	count_payers AS "Платящие покупатели",
	payers_share AS "Доля платящих покуп-ей",
	ROUND(AVG(avg_buy_interval)) AS "Дней между покупками (сред.)"
FROM 
	payers_share_analysis
JOIN
	classification USING (freq)
GROUP BY freq, count_buyers, count_payers, payers_share
ORDER BY "Дней между покупками (сред.)";

