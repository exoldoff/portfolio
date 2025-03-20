--Задача 1
-- Определим аномальные значения (выбросы) по значению перцентилей:
WITH limits AS (
    SELECT  
        PERCENTILE_DISC(0.99) WITHIN GROUP (ORDER BY total_area) AS total_area_limit,
        PERCENTILE_DISC(0.99) WITHIN GROUP (ORDER BY rooms) AS rooms_limit,
        PERCENTILE_DISC(0.99) WITHIN GROUP (ORDER BY balcony) AS balcony_limit,
        PERCENTILE_DISC(0.99) WITHIN GROUP (ORDER BY ceiling_height) AS ceiling_height_limit_h,
        PERCENTILE_DISC(0.01) WITHIN GROUP (ORDER BY ceiling_height) AS ceiling_height_limit_l
    FROM real_estate.flats     
),
-- Найдём id объявлений, которые не содержат выбросы:
filtered_id AS(
    SELECT id
    FROM real_estate.flats  
    WHERE 
        total_area < (SELECT total_area_limit FROM limits)
        AND (rooms < (SELECT rooms_limit FROM limits) OR rooms IS NULL)
        AND (balcony < (SELECT balcony_limit FROM limits) OR balcony IS NULL)
        AND ((ceiling_height < (SELECT ceiling_height_limit_h FROM limits)
            AND ceiling_height > (SELECT ceiling_height_limit_l FROM limits)) OR ceiling_height IS NULL)
    ),
filtered_adv AS (  -- Категоризация по продолжительности
	SELECT 
	*,
	CASE 
		WHEN days_exposition <= 30 THEN '1'
		WHEN days_exposition BETWEEN 31 AND 90 THEN '2' ----------- 1-меньше мес. 2-до квартала 3- до полугода 4 - больше
		WHEN days_exposition BETWEEN 91 AND 180 THEN '3'
		ELSE '4'
	END AS exp_interval
	FROM real_estate.advertisement a  
),
correct_city AS ( -- Категоризация по СПб/ЛО
	SELECT city_id,
		city,
		CASE
			WHEN city = 'Санкт-Петербург' THEN 'Санкт-Петербург'
			ELSE 'ЛО'
	END AS region
	FROM real_estate.city
),
flat_table AS ( -- формируем таблицу с квартирами + фильтр по выбросам и типу поселения
	SELECT *
		FROM real_estate.flats f 
		JOIN correct_city c USING (city_id)
		JOIN "type" t USING (type_id)
	WHERE id IN (SELECT * FROM filtered_id) AND "type" = 'город'
),
half_viborka AS ( -- рассчитываем цену за метр и соединяем квартиры с объявлениями
	SELECT 
		*,
		ROUND((last_price / total_area)::NUMERIC, -2) AS cost_per_metr
	FROM filtered_adv
	JOIN flat_table USING (id)
),
viborka AS ( -- отфильтровываем аномальные значения цен за метр и закрытые объявления. Получаем финальную выборку.
	SELECT * 
	FROM half_viborka
	WHERE (cost_per_metr BETWEEN 20000 AND 340000) AND days_exposition IS NOT NULL
),
analysis1 AS ( --cоздаём табличку со статистикой
	SELECT  
		CASE 
			WHEN exp_interval = '1' THEN 'Меньше месяца'
			WHEN exp_interval = '2' THEN 'До квартала'
			WHEN exp_interval = '3' THEN 'До полугода'
			WHEN exp_interval = '4' THEN 'Более полугода'
		END AS "Длительность_объяв.",
		region,
		COUNT(*) AS "Кол-во объявлений",
		ROUND(AVG(cost_per_metr)) AS "ср.цена_за_м",
		ROUND(STDDEV(cost_per_metr)) AS "цена_за_м_ст.откл.",
		PERCENTILE_DISC(0.5) WITHIN GROUP (ORDER BY cost_per_metr) AS "цена_за_м_мед.",
		ROUND(AVG(total_area)) AS "площадь_сред.",
		ROUND(STDDEV(total_area)) AS "площадь_ст.откл",
		PERCENTILE_DISC(0.5) WITHIN GROUP (ORDER BY total_area) AS "площадь_медиана",
		PERCENTILE_DISC(0.5) WITHIN GROUP (ORDER BY balcony) AS "балконы_медиана",
		PERCENTILE_DISC(0.5) WITHIN GROUP (ORDER BY rooms) AS "комнаты_медиана"
					-- (замечаем, что надо посчитать моду для комнат и балконов, так как значения медиан одинаковые для всех групп)
	FROM viborka
	GROUP BY "Длительность_объяв.", region
),
modal_rooms_pre AS (
	SELECT
		DISTINCT rooms,
		CASE 
			WHEN exp_interval = '1' THEN 'Меньше месяца'
			WHEN exp_interval = '2' THEN 'До квартала'
			WHEN exp_interval = '3' THEN 'До полугода'
			WHEN exp_interval = '4' THEN 'Более полугода'
		END AS "Длительность_объяв.",
		region,
		COUNT (rooms),
		MAX(COUNT(rooms)) OVER(PARTITION BY exp_interval, region) -- считаем фактические и максимальные
															  -- количества комнат и балконов в разрезе регионов и интервалов
	FROM viborka
	GROUP BY rooms, exp_interval, region
),
modal_rooms AS ( -- составляем табличку с модами комнат для каждой комбинации региона и интервала
	SELECT
		"Длительность_объяв.",
		region,
		rooms AS rooms_moda
	FROM modal_rooms_pre
	WHERE "count" = "max"
	ORDER BY "Длительность_объяв.", region DESC
),
-- повторяем то же самое для балконов:
modal_balcony_pre AS (
	SELECT
		DISTINCT balcony,
		CASE 
			WHEN exp_interval = '1' THEN 'Меньше месяца'
			WHEN exp_interval = '2' THEN 'До квартала'
			WHEN exp_interval = '3' THEN 'До полугода'
			WHEN exp_interval = '4' THEN 'Более полугода'
		END AS "Длительность_объяв.",
		region,
		COUNT (balcony),
		MAX(COUNT(balcony)) OVER(PARTITION BY exp_interval, region)
	FROM viborka
	WHERE balcony IS NOT NULL
	GROUP BY balcony, exp_interval, region
	ORDER BY "Длительность_объяв."
),
modal_balcony AS (
	SELECT
		"Длительность_объяв.",
		region,
		balcony AS balcony_moda
	FROM modal_balcony_pre
	WHERE "count" = "max"
	ORDER BY "Длительность_объяв.", region DESC
),
analysis_2 AS (
	SELECT  -- присоединяем моды к основной табличке со статистикой
		a.*, 
		mb.balcony_moda AS "мод.число.балк.",
		mr.rooms_moda AS "мод.число.комнат"
	FROM analysis1 a
	JOIN modal_rooms mr USING ("Длительность_объяв.", region)
	JOIN modal_balcony mb USING ("Длительность_объяв.", region)
	ORDER BY "Длительность_объяв.", region DESC
)
SELECT * FROM analysis_2;
--Задача 2
-- Определим аномальные значения (выбросы) по значению перцентилей:
WITH limits AS (
    SELECT  
        PERCENTILE_DISC(0.99) WITHIN GROUP (ORDER BY total_area) AS total_area_limit,
        PERCENTILE_DISC(0.99) WITHIN GROUP (ORDER BY rooms) AS rooms_limit,
        PERCENTILE_DISC(0.99) WITHIN GROUP (ORDER BY balcony) AS balcony_limit,
        PERCENTILE_DISC(0.99) WITHIN GROUP (ORDER BY ceiling_height) AS ceiling_height_limit_h,
        PERCENTILE_DISC(0.01) WITHIN GROUP (ORDER BY ceiling_height) AS ceiling_height_limit_l
    FROM real_estate.flats     
),
-- Найдём id объявлений, которые не содержат выбросы:
filtered_id AS(
    SELECT id
    FROM real_estate.flats  
    WHERE 
        total_area < (SELECT total_area_limit FROM limits)
        AND (rooms < (SELECT rooms_limit FROM limits) OR rooms IS NULL)
        AND (balcony < (SELECT balcony_limit FROM limits) OR balcony IS NULL)
        AND ((ceiling_height < (SELECT ceiling_height_limit_h FROM limits)
            AND ceiling_height > (SELECT ceiling_height_limit_l FROM limits)) OR ceiling_height IS NULL)
    ),
filtered_adv AS (  -- Категоризация по продолжительности+фильтр по годам публикации
	SELECT 
	*,
	CASE 
		WHEN days_exposition <= 30 THEN '1'
		WHEN days_exposition BETWEEN 31 AND 90 THEN '2' ----------- 1-меньше мес. 2-до квартала 3- до полугода 4 - больше
		WHEN days_exposition BETWEEN 91 AND 180 THEN '3'
		ELSE '4'
	END AS exp_interval
	FROM real_estate.advertisement a 
	WHERE date_trunc('year', first_day_exposition) BETWEEN '2015-01-01' AND '2018-01-01' 
),
correct_city AS ( -- Категоризация по СПб/ЛО
	SELECT city_id,
		city,
		CASE
			WHEN city = 'Санкт-Петербург' THEN 'Санкт-Петербург'
			ELSE 'ЛО'
	END AS region
	FROM real_estate.city
),
flat_table AS ( -- формируем таблицу с квартирами + фильтр по выбросам и типу поселения
	SELECT *
		FROM real_estate.flats f 
		JOIN correct_city c USING (city_id)
		JOIN "type" t USING (type_id)
	WHERE id IN (SELECT * FROM filtered_id) AND "type" = 'город'
),
half_viborka AS ( -- рассчитываем цену за метр и соединяем квартиры с объявлениями
	SELECT 
		*,
		ROUND((last_price / total_area)::NUMERIC, -2) AS cost_per_metr
	FROM filtered_adv
	JOIN flat_table USING (id)
),
viborka AS ( -- отфильтровываем аномальные значения цен за метр и закрытые объявления. Получаем финальную выборку.
	SELECT * 
	FROM half_viborka
	WHERE (cost_per_metr BETWEEN 20000 AND 340000) AND days_exposition IS NOT NULL
),
viborka_2 AS ( -- формируем таблицу с данными, которые пригодятся для 2 задачи.
	SELECT 
		id,
		TO_CHAR(first_day_exposition, 'Month') AS "exposition_start",
		TO_CHAR(first_day_exposition + days_exposition::int, 'Month') AS "exposition_end",
		cost_per_metr,
		total_area
	FROM viborka
),
start_counts AS (  -- считаем кол-во месяцев публикаций
    SELECT exposition_start AS month, COUNT(*) AS count
    FROM viborka_2
    GROUP BY exposition_start
),
end_counts AS (  -- считаем кол-во месяцев снятий
    SELECT exposition_end AS month, COUNT(*) AS count
    FROM  viborka_2
    GROUP BY exposition_end
),
analysis_3 AS(
	SELECT    --джойним таблицы и ранжируем столбцы. Ответ на вопросы 1,2 готов
	    e.month AS "Месяц",
	    s.count AS "Подано объявлений",
	    DENSE_RANK() OVER (ORDER BY s.count DESC) AS "Подано_ранг",
	    e.count AS "Снято объявлений",
	    DENSE_RANK() OVER (ORDER BY e.count DESC) AS "Снято_ранг"
	FROM start_counts s
	JOIN end_counts e ON s.month = e.month
	ORDER BY "Подано_ранг","Снято_ранг"
),
analysis_4 AS( -- анализируем сезонные изменения цен продаж
SELECT
DISTINCT exposition_end AS "Месяц",
ROUND(AVG(cost_per_metr) OVER (PARTITION BY exposition_end)::numeric, -3) AS "Цена_сред.",
ROUND(AVG(total_area) OVER (PARTITION BY exposition_end)::numeric) AS "Площ_сред."
FROM viborka_2
)
SELECT * FROM analysis_3
JOIN analysis_4 USING("Месяц");
--Задача 3
-- Определим аномальные значения (выбросы) по значению перцентилей:
WITH limits AS (
    SELECT  
        PERCENTILE_DISC(0.99) WITHIN GROUP (ORDER BY total_area) AS total_area_limit,
        PERCENTILE_DISC(0.99) WITHIN GROUP (ORDER BY rooms) AS rooms_limit,
        PERCENTILE_DISC(0.99) WITHIN GROUP (ORDER BY balcony) AS balcony_limit,
        PERCENTILE_DISC(0.99) WITHIN GROUP (ORDER BY ceiling_height) AS ceiling_height_limit_h,
        PERCENTILE_DISC(0.01) WITHIN GROUP (ORDER BY ceiling_height) AS ceiling_height_limit_l
    FROM real_estate.flats     
),
-- Найдём id объявлений, которые не содержат выбросы:
filtered_id AS(
    SELECT id
    FROM real_estate.flats  
    WHERE 
        total_area < (SELECT total_area_limit FROM limits)
        AND (rooms < (SELECT rooms_limit FROM limits) OR rooms IS NULL)
        AND (balcony < (SELECT balcony_limit FROM limits) OR balcony IS NULL)
        AND ((ceiling_height < (SELECT ceiling_height_limit_h FROM limits)
            AND ceiling_height > (SELECT ceiling_height_limit_l FROM limits)) OR ceiling_height IS NULL)
    ),
filtered_adv AS (  -- Категоризация по продолжительности
	SELECT 
	*,
	CASE 
		WHEN days_exposition <= 30 THEN '1'
		WHEN days_exposition BETWEEN 31 AND 90 THEN '2' ----------- 1-меньше мес. 2-до квартала 3- до полугода 4 - больше
		WHEN days_exposition BETWEEN 91 AND 180 THEN '3'
		ELSE '4'
	END AS exp_interval
	FROM real_estate.advertisement a 
),
correct_city AS ( -- Категоризация по СПб/ЛО
	SELECT city_id,
		city,
		CASE
			WHEN city = 'Санкт-Петербург' THEN 'Санкт-Петербург'
			ELSE 'ЛО'
	END AS region
	FROM real_estate.city
),
flat_table AS ( -- формируем таблицу с квартирами + фильтр по выбросам и типу поселения
	SELECT *
		FROM real_estate.flats f 
		JOIN correct_city c USING (city_id)
		JOIN "type" t USING (type_id)
	WHERE id IN (SELECT * FROM filtered_id) AND "type" = 'город'
),
half_viborka AS ( -- рассчитываем цену за метр и соединяем квартиры с объявлениями
	SELECT 
		*,
		ROUND((last_price / total_area)::NUMERIC, -2) AS cost_per_metr
	FROM filtered_adv
	JOIN flat_table USING (id)
),
viborka_3 AS( -- готовим выборку для задачи 3
SELECT
	id,
	city,
	cost_per_metr,
	total_area,
	days_exposition
FROM half_viborka -- фильтр по закрытым объявлениям не нужен в этой задаче, поэтому берем с таблицы, где этого фильтра ещё не было
WHERE (cost_per_metr BETWEEN 20000 AND 340000) AND region ='ЛО'
),
filter_city AS( -- отберём "верхнюю" половину нас.пунктов по кол-ву объявлений
	SELECT
		city,
		COUNT (*),
		NTILE(2) OVER(ORDER BY COUNT(*) DESC) AS rang
	FROM viborka_3
	GROUP BY city
),
viborka_4 AS ( -- финальная выборкад для задачи 3
	SELECT * 
	FROM viborka_3
	WHERE city IN (SELECT city FROM filter_city WHERE rang = '1')
),
analysis_5 AS ( --рассчитываем необходимые показатели.
	SELECT
		city AS "Город",
		COUNT(*) AS "Количество объявлений",
		ROUND(COUNT(*) FILTER (WHERE days_exposition IS NOT NULL) / COUNT(*)::NUMERIC, 2) AS "Доля снятых об.",
		ROUND(AVG(cost_per_metr), -2) AS "Сред. цена за кв.м.",
		ROUND(AVG(total_area)) AS "Сред. площадь",
		CEILING(AVG(days_exposition)) AS "Сред. продолж."
		FROM viborka_4
	GROUP BY city
),
-----------------------------------------------
--дополнительно: (не для заказчика)
analysis_6 AS( -- вспоминаем вузовский курс статистики и считаем коэффициенты вариации для нашей выборки. Они показывают разброс 
			   -- значений выборки относительно среднего выборки. (в процентах)
	SELECT 
		avg_avg_cpm AS "Матожидание ср. цены за кв.м.",
		ROUND((stdotkl_cpm / avg_avg_cpm::numeric)*100, 1) AS "к. вариации ср. цены за кв.м., %",
		avg_avg_area AS "Матожидание ср. площади",
		ROUND((stdotkl_area / avg_avg_area::numeric)*100, 1) AS "к. вариации ср. площади, %"
	FROM
		(
		SELECT
		ROUND(STDDEV("Сред. цена за кв.м.") OVER()) AS stdotkl_cpm,
		ROUND(AVG("Сред. цена за кв.м.") OVER()) AS avg_avg_cpm,
		ROUND(STDDEV("Сред. площадь") OVER()::NUMERIC, 2) AS stdotkl_area,
		ROUND(AVG("Сред. площадь") OVER()) AS avg_avg_area
		FROM analysis_5
		) AS sub
)
SELECT * FROM analysis_5;