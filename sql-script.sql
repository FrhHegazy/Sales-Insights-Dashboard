/* Create and populate dim_date only when it does not exist.
   Dates come from order_date in dbo.fact_sales_5000_workbench.
*/
IF OBJECT_ID(N'dbo.dim_date', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.dim_date
    (
        date_key     int          NOT NULL PRIMARY KEY,
        full_date    date         NOT NULL UNIQUE,
        [year]       smallint     NOT NULL,
        [quarter]    nvarchar(2)      NOT NULL,
        month_number tinyint      NOT NULL,
        month_name   nvarchar(3) NOT NULL,
        day_name     nvarchar(3) NOT NULL,
        is_weekend   bit          NOT NULL
    );

    DECLARE @StartDate date, @EndDate date;

    SELECT
        @StartDate = MIN(TRY_CONVERT(date, order_date)),
        @EndDate   = MAX(TRY_CONVERT(date, order_date))
    FROM dbo.fact_sales_5000_workbench;

    IF @StartDate IS NOT NULL AND @EndDate IS NOT NULL
    BEGIN
        ;WITH CalendarDates AS
        (
            SELECT @StartDate AS full_date
            UNION ALL
            SELECT DATEADD(day, 1, full_date)
            FROM CalendarDates
            WHERE full_date < @EndDate
        )
        INSERT dbo.dim_date
            (date_key, full_date, [year], [quarter], month_number,
             month_name, day_name, is_weekend)
        SELECT
            CONVERT(int, CONVERT(char(8), full_date, 112)),
            full_date,
            YEAR(full_date),
            CONCAT('Q', DATEPART(quarter, full_date)),
            MONTH(full_date),
            LEFT(DATENAME(month, full_date), 3),
            LEFT(DATENAME(weekday, full_date), 3),
            CASE WHEN DATEDIFF(day, CONVERT(date, '19000101'), full_date) % 7 IN (5, 6)
                 THEN 1 ELSE 0 END
        FROM CalendarDates
        OPTION (MAXRECURSION 0);
    END;
END;
GO

/* Add the database relationship from the fact table to dim_date if absent. */
IF COL_LENGTH(N'dbo.fact_sales_5000_workbench', N'date_key') IS NOT NULL
   AND NOT EXISTS
   (
       SELECT 1
       FROM sys.foreign_keys
       WHERE name = N'FK_fact_sales_5000_workbench_dim_date'
         AND parent_object_id = OBJECT_ID(N'dbo.fact_sales_5000_workbench')
   )
BEGIN
    ALTER TABLE dbo.fact_sales_5000_workbench
    ADD CONSTRAINT FK_fact_sales_5000_workbench_dim_date
        FOREIGN KEY (date_key) REFERENCES dbo.dim_date(date_key);
END;
GO

/* This view joins the existing sales view to the customer table only.
   Age uses DATEDIFF from birthdate to today's date; age_segment uses
   the dashboard bands shown by the user.
*/
IF OBJECT_ID(N'dbo.vw_fact_sales_analysis', N'V') IS NULL
    EXEC(N'
        CREATE VIEW dbo.vw_fact_sales_analysis
        AS
        WITH SalesWithAge AS
        (
            SELECT
                f.order_number,
                f.product_key,
                f.customer_key,
                f.order_date,
                f.shipping_date,
                f.due_date,
                f.sales_amount,
                f.quantity,
                f.price,
                f.date_key,
                DATEDIFF(YEAR, TRY_CONVERT(date, c.birthdate), TRY_CONVERT(date, c.create_date)) AS Age
            FROM dbo.fact_sales_5000_workbench AS f
            LEFT JOIN dbo.dim_customers_workbench AS c
                ON f.customer_key = c.customer_key
        )
        SELECT
           *,
            CASE
                WHEN Age IS NULL OR Age < 25 THEN N''Unknown''
                WHEN Age < 35 THEN N''25-34''
                WHEN Age < 45 THEN N''35-44''
                WHEN Age < 55 THEN N''45-54''
                ELSE N''55+''
            END AS age_segment
        FROM SalesWithAge;
    ');
GO



-- Top Product of each Category
WITH RankedProducts AS(
SELECT p.product_name,p.category,SUM(fs.sales_amount) AS TotalSales,
RANK() OVER (
            PARTITION BY p.category
            ORDER BY SUM(fs.sales_amount) DESC
        ) AS rn
FROM fact_sales_5000_workbench fs
JOIN dim_products_workbench p
ON fs.product_key = p.product_key
GROUP BY p.product_name,p.category
)

SELECT product_name,category,TotalSales
FROM RankedProducts
WHERE rn = 1;



-- Calculate the average sales for each country
-- and measure how much each order deviates from its country's average.
SELECT fs.order_number,c.country,fs.sales_amount, 
AVG(fs.sales_amount) OVER(
                            PARTITION BY c.country
                          ) AS CountryAvgSale,
fs.sales_amount - AVG(fs.sales_amount) OVER(
                                             PARTITION BY country
                                            ) AS deviation 
FROM fact_sales_5000_workbench fs
JOIN dim_customers_workbench c
ON fs.customer_key= c.customer_key;



-- Calculate each product's percentage of total category sales
-- and rank the top 5 products within each category
WITH ProductSales AS (
    SELECT product_name,category,SUM(sales_amount) AS ProductSales
    FROM fact_sales_5000_workbench fs
    JOIN dim_products_workbench p
        ON fs.product_key = p.product_key
    GROUP BY product_name, category
),
    CategoryTotalSales AS(
	SELECT product_name,category,ProductSales,
    SUM(ProductSales) OVER (PARTITION BY category) AS CategoryTotalSales,
    ProductSales * 100.0 /SUM(ProductSales) OVER (PARTITION BY category) AS PercentageOfCategory,
	RANK() OVER (PARTITION BY category
                 ORDER BY ProductSales DESC) AS rnk
   FROM ProductSales
)
SELECT *
FROM CategoryTotalSales
WHERE rnk <= 5;

