-- CIIN1021P | TEMA 04 | PREPARACION PARA EL ESTUDIANTE Y DOCENTE
-- Ejecutar completo en SSMS, conectado al Motor de base de datos.
-- SQL Server 2016 SP1 o posterior; no requiere las bases de temas previos.
-- Datos sinteticos. No se cargan personas ni datos reales del MINSA.
-- Crea objetos faltantes e inserta claves faltantes; no duplica la carga.
-- No borra tablas ni restaura cambios hechos por el usuario.
USE master;
GO
IF DB_ID(N'BDDataSaludTema04') IS NULL
    EXEC(N'CREATE DATABASE BDDataSaludTema04');
GO
USE BDDataSaludTema04;
GO
SET NOCOUNT ON;

IF OBJECT_ID(N'dbo.Establecimiento', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.Establecimiento (
        EstablecimientoId INT NOT NULL
            CONSTRAINT PK_T04_Establecimiento PRIMARY KEY,
        Nombre NVARCHAR(80) NOT NULL
    );
END;

INSERT dbo.Establecimiento (EstablecimientoId, Nombre)
SELECT s.Id, s.Nombre
FROM (VALUES
 (1,N'Centro simulado Norte'),(2,N'Centro simulado Sur'),
 (3,N'Centro simulado Este'),(4,N'Centro simulado Oeste'),
 (5,N'Centro simulado Central')
) AS s(Id,Nombre)
WHERE NOT EXISTS (
    SELECT 1 FROM dbo.Establecimiento e
    WHERE e.EstablecimientoId=s.Id
);

IF OBJECT_ID(N'dbo.Atencion', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.Atencion (
        AtencionId INT NOT NULL
            CONSTRAINT PK_T04_Atencion PRIMARY KEY CLUSTERED,
        EstablecimientoId INT NOT NULL,
        FechaAtencion DATE NOT NULL,
        TipoAtencion VARCHAR(20) NOT NULL,
        DuracionMinutos INT NOT NULL,
        EstadoRegistro VARCHAR(10) NOT NULL,
        Lote VARCHAR(16) NOT NULL,
        CONSTRAINT FK_T04_Atencion_Establecimiento
            FOREIGN KEY (EstablecimientoId)
            REFERENCES dbo.Establecimiento(EstablecimientoId),
        CONSTRAINT CK_T04_Duracion CHECK (DuracionMinutos>0),
        CONSTRAINT CK_T04_Estado
            CHECK (EstadoRegistro IN ('VALIDO','OBSERVADO','PRUEBA'))
    );
END;

-- Las nueve filas pequenas se reutilizan en los ejercicios 02 al 06.
INSERT dbo.Atencion
 (AtencionId,EstablecimientoId,FechaAtencion,TipoAtencion,
  DuracionMinutos,EstadoRegistro,Lote)
SELECT s.Id,s.Establecimiento,s.Fecha,s.Tipo,s.Minutos,s.Estado,'T04_DEMO'
FROM (VALUES
 (1101,1,CONVERT(date,'20261001'),'CONSULTA',20,'VALIDO'),
 (1102,2,CONVERT(date,'20261002'),'CONTROL',15,'VALIDO'),
 (1103,1,CONVERT(date,'20261003'),'VACUNACION',10,'VALIDO'),
 (1104,3,CONVERT(date,'20261004'),'LABORATORIO',30,'OBSERVADO'),
 (1105,2,CONVERT(date,'20261005'),'CONSULTA',25,'VALIDO'),
 (1106,3,CONVERT(date,'20261006'),'CONTROL',18,'VALIDO'),
 (1107,1,CONVERT(date,'20261007'),'VACUNACION',12,'VALIDO'),
 (1108,2,CONVERT(date,'20261008'),'LABORATORIO',35,'OBSERVADO'),
 (1199,1,CONVERT(date,'20261009'),'CONSULTA',5,'PRUEBA')
) AS s(Id,Establecimiento,Fecha,Tipo,Minutos,Estado)
WHERE NOT EXISTS (SELECT 1 FROM dbo.Atencion a WHERE a.AtencionId=s.Id);

-- Volumen exclusivamente didactico para observar planes y lecturas.
-- No es una carga ETL del MINSA ni una practica de Big Data.
;WITH Digito AS (
    SELECT n FROM (VALUES(0),(1),(2),(3),(4),(5),(6),(7),(8),(9)) d(n)
), Numeros AS (
    SELECT TOP (50000)
        CONVERT(int,ROW_NUMBER() OVER (ORDER BY (SELECT NULL))) AS n
    FROM Digito a CROSS JOIN Digito b CROSS JOIN Digito c
         CROSS JOIN Digito d CROSS JOIN Digito e
)
INSERT dbo.Atencion
 (AtencionId,EstablecimientoId,FechaAtencion,TipoAtencion,
  DuracionMinutos,EstadoRegistro,Lote)
SELECT 100000+n,1+(n%5),
       DATEADD(day,n%365,CONVERT(date,'20251101')),
       CASE n%3 WHEN 0 THEN 'CONSULTA'
                WHEN 1 THEN 'CONTROL' ELSE 'VACUNACION' END,
       10+(n%31),'VALIDO','T04_REND'
FROM Numeros x
WHERE NOT EXISTS (
    SELECT 1 FROM dbo.Atencion a WHERE a.AtencionId=100000+x.n
);
GO

SELECT DB_NAME() AS BaseActiva,
       (SELECT COUNT(*) FROM dbo.Establecimiento) AS Establecimientos,
       COUNT(*) AS Atenciones,
       SUM(CASE WHEN Lote='T04_DEMO' THEN 1 ELSE 0 END) AS Demostracion,
       SUM(CASE WHEN Lote='T04_REND' THEN 1 ELSE 0 END) AS Rendimiento
FROM dbo.Atencion;
-- Esperado: BDDataSaludTema04 | 5 | 50009 | 9 | 50000

SELECT AtencionId,EstablecimientoId,FechaAtencion,TipoAtencion,
       DuracionMinutos,EstadoRegistro
FROM dbo.Atencion
WHERE Lote='T04_DEMO'
ORDER BY AtencionId;
GO
-- No se crea el indice experimental: se construye en el ejercicio 01.
