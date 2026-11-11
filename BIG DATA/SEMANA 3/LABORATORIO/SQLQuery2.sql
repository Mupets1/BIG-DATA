USE BDDataSaludTema01;
GO
DROP PROCEDURE IF EXISTS dbo.usp_DispensarVacuna;
DROP TABLE IF EXISTS dbo.AlertaStock;
DROP TABLE IF EXISTS dbo.DispensacionVacuna;
DROP TABLE IF EXISTS dbo.StockVacuna;
GO
-- Stock de vacunas por establecimiento (equivale a Medicamentos.Stock de la guia oficial).
CREATE TABLE dbo.StockVacuna(
    StockVacunaId INT IDENTITY(1,1)
        CONSTRAINT PK_StockVacuna PRIMARY KEY,
    EstablecimientoId INT NOT NULL
        CONSTRAINT FK_StockVacuna_Establecimiento
        REFERENCES dbo.EstablecimientoSalud(EstablecimientoId),
    Vacuna VARCHAR(30) NOT NULL,
    Stock INT NOT NULL,
    StockMinimo INT NOT NULL,
    CONSTRAINT UQ_StockVacuna UNIQUE (EstablecimientoId, Vacuna),
    CONSTRAINT CK_StockVacuna_Stock CHECK (Stock >= 0)
);
-- Cada vacuna aplicada (equivale a VentasFarmacia de la guia oficial).
CREATE TABLE dbo.DispensacionVacuna(
    DispensacionId INT IDENTITY(1,1)
        CONSTRAINT PK_DispensacionVacuna PRIMARY KEY,
    AtencionId INT NOT NULL
        CONSTRAINT FK_Dispensacion_Atencion REFERENCES dbo.Atencion(AtencionId),
    StockVacunaId INT NOT NULL
        CONSTRAINT FK_Dispensacion_Stock REFERENCES dbo.StockVacuna(StockVacunaId),
    Dosis INT NOT NULL
        CONSTRAINT CK_Dispensacion_Dosis CHECK (Dosis > 0),
    FechaDispensacion DATETIME2 NOT NULL
        CONSTRAINT DF_Dispensacion_Fecha DEFAULT (SYSDATETIME()),
    UsuarioBD NVARCHAR(128) NOT NULL
        CONSTRAINT DF_Dispensacion_Usuario DEFAULT (SUSER_SNAME())
);
-- Alerta de stock bajo: es secundaria; si falla, la vacunacion NO debe cancelarse.
CREATE TABLE dbo.AlertaStock(
    AlertaStockId INT IDENTITY(1,1)
        CONSTRAINT PK_AlertaStock PRIMARY KEY,
    StockVacunaId INT NOT NULL,
    StockRestante INT NOT NULL,
    FechaAlerta DATETIME2 NOT NULL
        CONSTRAINT DF_AlertaStock_Fecha DEFAULT (SYSDATETIME())
);
GO
INSERT INTO dbo.StockVacuna (EstablecimientoId, Vacuna, Stock, StockMinimo)
VALUES (1, 'INFLUENZA', 5, 3),
       (1, 'HEPATITIS B', 1, 2),
       (2, 'INFLUENZA', 10, 3);
GO
SELECT StockVacunaId, EstablecimientoId, Vacuna, Stock, StockMinimo
FROM dbo.StockVacuna ORDER BY StockVacunaId;
GO

--paso2
--completa el procedimiento
CREATE OR ALTER PROCEDURE dbo.usp_DispensarVacuna
    @PacienteId INT,
    @EstablecimientoId INT,
    @Vacuna VARCHAR(30),
    @Dosis INT = 1,
    @SimularFalloAlerta BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @StockVacunaId INT, @StockMinimo INT, @StockRestante INT,
            @AtencionId INT, @Clasificacion VARCHAR(20), @Mensaje VARCHAR(300);

    -- 1) Validar ANTES de abrir la transaccion
    IF @Dosis IS NULL OR @Dosis <= 0
    BEGIN
        ;THROW 56003, 'La cantidad de dosis debe ser mayor que cero.', 1;
    END;

    SELECT @StockVacunaId = StockVacunaId, @StockMinimo = StockMinimo
    FROM dbo.StockVacuna
    WHERE EstablecimientoId = @EstablecimientoId AND Vacuna = @Vacuna;

    IF @StockVacunaId IS NULL
    BEGIN
        ;THROW 56002, 'La vacuna no esta registrada en el establecimiento indicado.', 1;
    END;

    BEGIN TRY
        BEGIN TRANSACTION;

        -- 2) Descontar el stock SOLO si alcanza.
        UPDATE dbo.StockVacuna
        SET Stock = Stock - @Dosis
        WHERE StockVacunaId = @StockVacunaId
          AND Stock >= @Dosis;

        IF @@ROWCOUNT = 0
        BEGIN
            ;THROW 56001, 'Stock insuficiente: la vacunacion no se registro.', 1;
        END;

        -- 3) Registrar la atencion
        EXEC dbo.usp_RegistrarAtencion
            @PacienteId = @PacienteId, @EstablecimientoId = @EstablecimientoId,
            @TipoAtencion = 'VACUNACION', @DuracionMinutos = 10,
            @AtencionId = @AtencionId OUTPUT, @Clasificacion = @Clasificacion OUTPUT,
            @Mensaje = @Mensaje OUTPUT;

        -- 4) Registrar la dispensacion.
        INSERT INTO dbo.DispensacionVacuna (AtencionId, StockVacunaId, Dosis)
        VALUES (@AtencionId, @StockVacunaId, @Dosis);

        SELECT @StockRestante = Stock FROM dbo.StockVacuna WHERE StockVacunaId = @StockVacunaId;

        -- 5) Alerta de stock bajo protegida con un punto de guardado.
        SAVE TRANSACTION AntesDeAlerta;
        BEGIN TRY
            IF @SimularFalloAlerta = 1
            BEGIN
                ;THROW 56004, 'Fallo simulado al registrar la alerta de stock.', 1;
            END;

            IF @StockRestante < @StockMinimo
            BEGIN
                INSERT INTO dbo.AlertaStock (StockVacunaId, StockRestante)
                VALUES (@StockVacunaId, @StockRestante);
            END;
        END TRY
        BEGIN CATCH
            IF XACT_STATE() = 1
            BEGIN
                ROLLBACK TRANSACTION AntesDeAlerta;
                PRINT 'No se pudo registrar la alerta; la vacunacion se mantiene.';
            END
            ELSE
            BEGIN
                ;THROW;
            END;
        END CATCH;

        -- 3) Confirmar la transaccion
        COMMIT TRANSACTION;

        SELECT @AtencionId AS AtencionId, @StockRestante AS StockRestante,
               'Vacunacion registrada.' AS Resultado;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0
        BEGIN
            ROLLBACK TRANSACTION;
        END;
        ;THROW;
    END CATCH;
END;
GO

-- Prueba 1: vacunacion normal (PAC-001 en EST-001, INFLUENZA, 1 dosis).
EXEC dbo.usp_DispensarVacuna @PacienteId = 1, @EstablecimientoId = 1,
     @Vacuna = 'INFLUENZA', @Dosis = 1;

SELECT Vacuna, Stock FROM dbo.StockVacuna WHERE EstablecimientoId = 1 ORDER BY Vacuna;
GO
-- Prueba 2: stock insuficiente (HEPATITIS B tiene 1 dosis y se piden 2).
DECLARE @Antes INT = (SELECT COUNT(*) FROM dbo.Atencion);
BEGIN TRY
    EXEC dbo.usp_DispensarVacuna @PacienteId = 1, @EstablecimientoId = 1,
         @Vacuna = 'HEPATITIS B', @Dosis = 2;
END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS NumeroError, ERROR_MESSAGE() AS MensajeError,
           @@TRANCOUNT AS TransaccionesAbiertas;
END CATCH;

SELECT Stock AS StockHepatitisB
FROM dbo.StockVacuna WHERE EstablecimientoId = 1 AND Vacuna = 'HEPATITIS B';
SELECT COUNT(*) - @Antes AS AtencionesNuevas FROM dbo.Atencion;
GO
-- Prueba 3 (prediccion): PAC-003 esta INACTIVO. El stock se descuenta en el paso 2,
-- pero la atencion falla en el paso 3. Cuanto stock de INFLUENZA quedara?
BEGIN TRY
    EXEC dbo.usp_DispensarVacuna @PacienteId = 3, @EstablecimientoId = 1,
         @Vacuna = 'INFLUENZA', @Dosis = 1;
END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS NumeroError, ERROR_MESSAGE() AS MensajeError,
           @@TRANCOUNT AS TransaccionesAbiertas;
END CATCH;

SELECT Stock AS StockInfluenza
FROM dbo.StockVacuna WHERE EstablecimientoId = 1 AND Vacuna = 'INFLUENZA';
GO
-- Prueba 4b: 1 dosis con fallo simulado en la alerta: la vacunacion se mantiene.
EXEC dbo.usp_DispensarVacuna @PacienteId = 2, @EstablecimientoId = 1,
     @Vacuna = 'INFLUENZA', @Dosis = 1, @SimularFalloAlerta = 1;

SELECT Vacuna, Stock FROM dbo.StockVacuna WHERE EstablecimientoId = 1 ORDER BY Vacuna;
SELECT AlertaStockId, StockVacunaId, StockRestante FROM dbo.AlertaStock ORDER BY AlertaStockId;
SELECT COUNT(*) AS Dispensaciones FROM dbo.DispensacionVacuna;
GO


--ejercisio02
USE BDDataSaludTema01;
GO
-- Reinicio: permite repetir el ejercicio sin errores (no hace falta memorizarlo).
-- Primero usuarios y roles (nivel base de datos), luego logins (nivel servidor).
DROP USER IF EXISTS usuario_analista;
DROP USER IF EXISTS usuario_auditor;
DROP USER IF EXISTS usuario_administrador;
DROP ROLE IF EXISTS rol_lectura_general;
DROP ROLE IF EXISTS rol_analista;
DROP ROLE IF EXISTS rol_auditor;
DROP ROLE IF EXISTS rol_administrador;
GO
IF SUSER_ID('login_analista') IS NOT NULL
BEGIN
    DROP LOGIN login_analista;
END;
IF SUSER_ID('login_auditor') IS NOT NULL
BEGIN
    DROP LOGIN login_auditor;
END;
IF SUSER_ID('login_administrador') IS NOT NULL
BEGIN
    DROP LOGIN login_administrador;
END;
GO
-- Paso 1. Nivel SERVIDOR: un LOGIN por persona, para entrar a la instancia.
CREATE LOGIN login_analista WITH PASSWORD = 'DataSalud#Analista26', CHECK_POLICY = ON;
CREATE LOGIN login_auditor WITH PASSWORD = 'DataSalud#Auditor26', CHECK_POLICY = ON;
CREATE LOGIN login_administrador WITH PASSWORD = 'DataSalud#Admin2026', CHECK_POLICY = ON;
GO
-- Nivel BASE DE DATOS: un USER asociado a cada LOGIN.
CREATE USER usuario_analista FOR LOGIN login_analista;
CREATE USER usuario_auditor FOR LOGIN login_auditor;
CREATE USER usuario_administrador FOR LOGIN login_administrador;
GO
SELECT name AS LoginServidor, type_desc FROM sys.server_principals
WHERE name LIKE 'login[_]%' ORDER BY name;
SELECT name AS UsuarioBase, type_desc FROM sys.database_principals
WHERE name LIKE 'usuario[_]%' ORDER BY name;
GO
-- Paso 2. Roles: los permisos se dan al ROL, no a cada persona.
-- TODO 1 (concepto: crear un rol de base de datos)
CREATE ROLE rol_analista;
CREATE ROLE rol_auditor;
CREATE ROLE rol_administrador;
GO
-- TODO 2 (concepto: agregar un usuario a un rol existente)
ALTER ROLE rol_analista ADD MEMBER usuario_analista;
ALTER ROLE rol_auditor ADD MEMBER usuario_auditor;
ALTER ROLE rol_administrador ADD MEMBER usuario_administrador;
GO
-- Paso 3. Permisos segun la tabla de perfiles (minimo privilegio).
-- Analista: solo consulta atenciones.
GRANT SELECT ON dbo.Atencion TO rol_analista;

-- Auditor: consulta atenciones y su trazabilidad; nunca las modifica.
GRANT SELECT ON dbo.Atencion TO rol_auditor;
-- TODO 3 (concepto: permiso de lectura sobre la auditoria)
GRANT SELECT ON dbo.AuditoriaAtencion TO rol_auditor;
-- TODO 4 (concepto: negar de forma explicita)
DENY INSERT, UPDATE, DELETE ON dbo.Atencion TO rol_auditor;

-- Administrador: mantiene atenciones, lee la auditoria y dispensa vacunas.
-- TODO 5 (concepto: los cuatro permisos de mantenimiento)
GRANT SELECT, INSERT, UPDATE, DELETE ON dbo.Atencion TO rol_administrador;
GRANT SELECT ON dbo.AuditoriaAtencion TO rol_administrador;
GRANT SELECT ON dbo.StockVacuna TO rol_administrador;
GRANT EXECUTE ON dbo.usp_DispensarVacuna TO rol_administrador;
GO
-- Paso 4. Pruebas: EXECUTE AS LOGIN suplanta a la persona sin cerrar tu sesion.
EXECUTE AS LOGIN = 'login_analista';
SELECT SUSER_SNAME() AS LoginActual, USER_NAME() AS UsuarioActual;
SELECT TOP (3) AtencionId, TipoAtencion, DuracionMinutos FROM dbo.Atencion ORDER BY AtencionId;
BEGIN TRY
    DELETE FROM dbo.Atencion WHERE AtencionId = -1;   -- -1 no existe: no se borra nada real
END TRY
BEGIN CATCH
    SELECT 'analista: DELETE' AS Prueba, ERROR_NUMBER() AS NumeroError,
           ERROR_MESSAGE() AS MensajeError;
END CATCH;
REVERT;
GO
EXECUTE AS LOGIN = 'login_auditor';
SELECT COUNT(*) AS FilasAuditoriaVisibles FROM dbo.AuditoriaAtencion;
BEGIN TRY
    UPDATE dbo.Atencion SET DuracionMinutos = 99 WHERE AtencionId = -1;
END TRY
BEGIN CATCH
    SELECT 'auditor: UPDATE' AS Prueba, ERROR_NUMBER() AS NumeroError,
           ERROR_MESSAGE() AS MensajeError;
END CATCH;
REVERT;
GO
SELECT SUSER_SNAME() AS DebeSerTuLogin;   -- confirma que REVERT te devolvio tu identidad
GO
-- Paso 5. Un rol demasiado amplio: SELECT sobre TODO el esquema dbo.
CREATE ROLE rol_lectura_general;
GRANT SELECT ON SCHEMA::dbo TO rol_lectura_general;
ALTER ROLE rol_lectura_general ADD MEMBER usuario_analista;
GO
-- Prediccion: el analista puede leer ahora la auditoria?
EXECUTE AS LOGIN = 'login_analista';
SELECT COUNT(*) AS AuditoriaLeidaPorAnalista FROM dbo.AuditoriaAtencion;
REVERT;
GO
-- La politica dice que el analista NO accede a la auditoria. DENY gana sobre cualquier GRANT.
DENY SELECT ON dbo.AuditoriaAtencion TO rol_analista;
GO
EXECUTE AS LOGIN = 'login_analista';
BEGIN TRY
    SELECT COUNT(*) AS AuditoriaLeidaPorAnalista FROM dbo.AuditoriaAtencion;
END TRY
BEGIN CATCH
    SELECT 'con DENY' AS Prueba, ERROR_NUMBER() AS NumeroError, ERROR_MESSAGE() AS MensajeError;
END CATCH;
REVERT;
GO
-- REVOKE retira el DENY, pero no otorga nada: el analista vuelve a leer por el rol amplio.
REVOKE SELECT ON dbo.AuditoriaAtencion FROM rol_analista;
GO
EXECUTE AS LOGIN = 'login_analista';
SELECT COUNT(*) AS AuditoriaLeidaPorAnalista FROM dbo.AuditoriaAtencion;
REVERT;
GO
-- Cierre con minimo privilegio: se elimina el rol amplio y la politica queda escrita con DENY.
ALTER ROLE rol_lectura_general DROP MEMBER usuario_analista;
DROP ROLE rol_lectura_general;
DENY SELECT ON dbo.AuditoriaAtencion TO rol_analista;
GO
-- Paso 6. El procedimiento como unica puerta al stock.
-- El administrador tiene EXECUTE sobre usp_DispensarVacuna, pero NO tiene UPDATE sobre StockVacuna.
EXECUTE AS LOGIN = 'login_administrador';
BEGIN TRY
    UPDATE dbo.StockVacuna SET Stock = Stock + 100 WHERE EstablecimientoId = 2;
END TRY
BEGIN CATCH
    SELECT 'UPDATE directo' AS Intento, ERROR_NUMBER() AS NumeroError,
           ERROR_MESSAGE() AS MensajeError;
END CATCH;
EXEC dbo.usp_DispensarVacuna @PacienteId = 2, @EstablecimientoId = 2,
     @Vacuna = 'INFLUENZA', @Dosis = 1;
REVERT;
GO
-- Quien hizo la dispensacion? (la auditoria del Tema 02 tambien lo registra)
SELECT TOP (1) DispensacionId, Dosis, UsuarioBD
FROM dbo.DispensacionVacuna ORDER BY DispensacionId DESC;
SELECT TOP (1) AuditoriaId, Operacion, UsuarioBD
FROM dbo.AuditoriaAtencion ORDER BY AuditoriaId DESC;
GO
-- Evidencia: permisos otorgados (GRANT) y negados (DENY) por rol.
SELECT pr.name AS Rol, pe.state_desc AS Estado, pe.permission_name AS Permiso,
       OBJECT_NAME(pe.major_id) AS Objeto, COL_NAME(pe.major_id, pe.minor_id) AS Columna
FROM sys.database_permissions AS pe
INNER JOIN sys.database_principals AS pr
    ON pr.principal_id = pe.grantee_principal_id
WHERE pr.name LIKE 'rol[_]%'
ORDER BY Rol, Objeto, Permiso;
GO
USE BDDataSaludTema01;
GO
DROP PROCEDURE IF EXISTS dbo.usp_ConsultarDetalleClinico;
DROP TABLE IF EXISTS dbo.LogAccesoPaciente;
DROP TABLE IF EXISTS dbo.DetalleClinicoRestringido;
GO
-- Detalle clinico: la columna Diagnostico es un dato sensible (Ley 29733).
CREATE TABLE dbo.DetalleClinicoRestringido(
    DetalleClinicoId INT IDENTITY(1,1)
        CONSTRAINT PK_DetalleClinicoRestringido PRIMARY KEY,
    PacienteId INT NOT NULL
        CONSTRAINT FK_DetalleClinico_Paciente REFERENCES dbo.Paciente(PacienteId),
    NivelRiesgo VARCHAR(10) NOT NULL
        CONSTRAINT CK_DetalleClinico_Riesgo CHECK (NivelRiesgo IN ('BAJO','MEDIO','ALTO')),
    Diagnostico VARCHAR(100) NOT NULL,
    FechaRegistro DATE NOT NULL
        CONSTRAINT DF_DetalleClinico_Fecha DEFAULT (CAST(SYSDATETIME() AS DATE))
);
-- Registro de accesos (equivale a Log_Accesos de la guia oficial).
CREATE TABLE dbo.LogAccesoPaciente(
    LogId BIGINT IDENTITY(1,1)
        CONSTRAINT PK_LogAccesoPaciente PRIMARY KEY,
    Usuario NVARCHAR(128) NOT NULL,
    FechaAcceso DATETIME2 NOT NULL
        CONSTRAINT DF_LogAcceso_Fecha DEFAULT (SYSDATETIME()),
    AccionRealizada VARCHAR(60) NOT NULL,
    PacienteId INT NULL
);
GO
INSERT INTO dbo.DetalleClinicoRestringido (PacienteId, NivelRiesgo, Diagnostico)
VALUES (1, 'BAJO', 'Control preventivo (dato sintetico)'),
       (2, 'MEDIO', 'Seguimiento de vacunacion (dato sintetico)'),
       (3, 'ALTO', 'Evaluacion pendiente (dato sintetico)');
GO
-- R1. Analista: ve el detalle clinico, pero nunca la columna Diagnostico.
-- (escribe aqui tu codigo)
GO
-- R2. Auditor: no accede al detalle clinico.
-- (escribe aqui tu codigo)
GO
-- R3. Procedimiento de consulta que registra cada acceso.
CREATE OR ALTER PROCEDURE dbo.usp_ConsultarDetalleClinico
    @CodigoPaciente VARCHAR(20)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @PacienteId INT;
    -- 1) Buscar el PacienteId a partir del codigo.
    -- 2) Si no existe, lanzar el error 57001.
    -- 3) Registrar el acceso en dbo.LogAccesoPaciente (quien, que accion, que paciente).
    -- 4) Devolver el detalle clinico del paciente.
    -- (escribe aqui tu codigo)
END;
GO
-- R4. Administrador: consulta el detalle SOLO mediante el procedimiento.
-- (escribe aqui tu codigo)
GO
-- Casos de prueba (no cambies este bloque; compara con el resultado esperado de la guia).
-- Caso 1. Analista: columnas permitidas.
EXECUTE AS LOGIN = 'login_analista';
SELECT PacienteId, NivelRiesgo, FechaRegistro FROM dbo.DetalleClinicoRestringido;
-- Caso 2. Analista: la columna Diagnostico.
BEGIN TRY
    SELECT PacienteId, Diagnostico FROM dbo.DetalleClinicoRestringido;
END TRY
BEGIN CATCH
    SELECT 'Caso 2' AS Caso, ERROR_NUMBER() AS NumeroError, ERROR_MESSAGE() AS MensajeError;
END CATCH;
REVERT;
GO
-- Caso 3. Auditor: cualquier lectura del detalle.
EXECUTE AS LOGIN = 'login_auditor';
BEGIN TRY
    SELECT TOP (1) PacienteId FROM dbo.DetalleClinicoRestringido;
END TRY
BEGIN CATCH
    SELECT 'Caso 3' AS Caso, ERROR_NUMBER() AS NumeroError, ERROR_MESSAGE() AS MensajeError;
END CATCH;
REVERT;
GO
-- Caso 4. Administrador: lectura directa (debe fallar) y por el procedimiento (debe funcionar).
EXECUTE AS LOGIN = 'login_administrador';
BEGIN TRY
    SELECT * FROM dbo.DetalleClinicoRestringido;
END TRY
BEGIN CATCH
    SELECT 'Caso 4' AS Caso, ERROR_NUMBER() AS NumeroError, ERROR_MESSAGE() AS MensajeError;
END CATCH;
EXEC dbo.usp_ConsultarDetalleClinico @CodigoPaciente = 'PAC-002';
-- Caso 5. Paciente inexistente.
BEGIN TRY
    EXEC dbo.usp_ConsultarDetalleClinico @CodigoPaciente = 'PAC-999';
END TRY
BEGIN CATCH
    SELECT 'Caso 5' AS Caso, ERROR_NUMBER() AS NumeroError, ERROR_MESSAGE() AS MensajeError;
END CATCH;
REVERT;
GO
-- Caso 6. El registro de accesos.
SELECT LogId, Usuario, AccionRealizada, PacienteId FROM dbo.LogAccesoPaciente ORDER BY LogId;
GO
USE BDDataSaludTema01;
GO
DROP TABLE IF EXISTS dbo.AtencionRendimientoTema03;
GO
CREATE TABLE dbo.AtencionRendimientoTema03(
    AtencionRendimientoId INT IDENTITY(1,1)
        CONSTRAINT PK_AtencionRendimientoTema03 PRIMARY KEY,
    EstablecimientoId INT NOT NULL,
    FechaAtencion DATETIME2 NOT NULL,
    TipoAtencion VARCHAR(30) NOT NULL,
    DuracionMinutos INT NOT NULL
);
GO
-- 50 000 atenciones sinteticas (no hace falta memorizar este bloque).
WITH Numeros AS
(
    SELECT TOP (50000) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS Numero
    FROM sys.all_objects AS A
    CROSS JOIN sys.all_objects AS B
)
INSERT INTO dbo.AtencionRendimientoTema03
    (EstablecimientoId, FechaAtencion, TipoAtencion, DuracionMinutos)
SELECT ((Numero * 17) % 50) + 1,
       DATEADD(MINUTE, Numero % 1440,
               DATEADD(DAY, Numero % 365, CAST('2025-09-01' AS DATETIME2))),
       CASE Numero % 3 WHEN 0 THEN 'CONSULTA' WHEN 1 THEN 'CONTROL' ELSE 'VACUNACION' END,
       ((Numero * 7) % 50) + 10
FROM Numeros;
GO
SELECT COUNT(*) AS TotalAtenciones FROM dbo.AtencionRendimientoTema03;
EXEC sp_helpindex 'dbo.AtencionRendimientoTema03';
GO
-- Antes de ejecutar: activa Include Actual Execution Plan (Ctrl + M).
SET STATISTICS IO ON;
SET STATISTICS TIME ON;
GO
-- Consulta A: reporte de un establecimiento en un mes.
SELECT AtencionRendimientoId, EstablecimientoId, FechaAtencion
FROM dbo.AtencionRendimientoTema03
WHERE EstablecimientoId = 17
  AND FechaAtencion >= '2026-07-01'
  AND FechaAtencion < '2026-08-01';
GO
-- Consulta B: el mismo filtro (primera quincena) con dos columnas mas en el SELECT.
SELECT AtencionRendimientoId, FechaAtencion, TipoAtencion, DuracionMinutos
FROM dbo.AtencionRendimientoTema03
WHERE EstablecimientoId = 17
  AND FechaAtencion >= '2026-07-01'
  AND FechaAtencion < '2026-07-16';
GO
-- Decision 1: indice para la consulta A (igualdad primero, rango despues).
-- (escribe aqui tu codigo)
GO
-- Vuelve a ejecutar la consulta A y luego la B. Observa el plan de la B.
-- Decision 2: la consulta B muestra Key Lookup. Ajusta el indice para cubrirla.
-- (escribe aqui tu codigo)
GO
-- Cierre del ejercicio.
SET STATISTICS IO OFF;
SET STATISTICS TIME OFF;
GO
SELECT name AS Indice, type_desc AS Tipo
FROM sys.indexes
WHERE object_id = OBJECT_ID('dbo.AtencionRendimientoTema03')
ORDER BY index_id;
GO

