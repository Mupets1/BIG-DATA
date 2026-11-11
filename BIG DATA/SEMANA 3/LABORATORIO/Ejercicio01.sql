use BDDataSaludTema01;
go
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
 
    -- 1) Validar ANTES de abrir la transaccion: asi la transaccion dura lo minimo. 
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
        -- TODO 1 (concepto: verificar y descontar stock) 

        -- 1) Descuenta las dosis solo cuando el inventario alcanza. 

        -- 2) La condicion debe formar parte del mismo UPDATE. 

        -- 3) Si ninguna fila se actualiza, genera el error de stock insuficiente. 

 
        UPDATE dbo.StockVacuna 
        SET Stock = Stock - @Dosis 
        WHERE StockVacunaId = @StockVacunaId 
          AND Stock >= @Dosis; 
 
        IF @@ROWCOUNT = 0 
        BEGIN 
            ;THROW 56001, 'Stock insuficiente: la vacunacion no se registro.', 1; 
        END; 
        -- 3) Registrar la atencion con el procedimiento del Tema 01 
        --    (valida paciente y establecimiento). 
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
                -- TODO 2 (concepto: deshacer solo la alerta, recuperacion parcial) 
                ROLLBACK TRANSACTION AntesDeAlerta; 
                PRINT 'No se pudo registrar la alerta; la vacunacion se mantiene.'; 
            END 
            ELSE 
            BEGIN 
                ;THROW; 
            END;
        END CATCH; 
 
        -- TODO 3 (concepto: confirmar la transaccion) 
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
--prueba1
EXEC dbo.usp_DispensarVacuna
    @PacienteId = 1,
    @EstablecimientoId = 1,
    @Vacuna = 'INFLUENZA',
    @Dosis = 1;

SELECT Vacuna, Stock
FROM dbo.StockVacuna
WHERE EstablecimientoId = 1
ORDER BY Vacuna;

--prueba2

DECLARE @Antes INT = (SELECT COUNT(*) FROM dbo.Atencion);

BEGIN TRY
    EXEC dbo.usp_DispensarVacuna
        @PacienteId = 1,
        @EstablecimientoId = 1,
        @Vacuna = 'HEPATITIS B',
        @Dosis = 2;
END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS NumeroError,
           ERROR_MESSAGE() AS MensajeError,
           @@TRANCOUNT AS TransaccionesAbiertas;
END CATCH;

SELECT Stock AS StockHepatitisB
FROM dbo.StockVacuna
WHERE EstablecimientoId = 1
AND Vacuna = 'HEPATITIS B';

SELECT COUNT(*) - @Antes AS AtencionesNuevas
FROM dbo.Atencion;
GO

--prueba3
BEGIN TRY
    EXEC dbo.usp_DispensarVacuna
        @PacienteId = 3,
        @EstablecimientoId = 1,
        @Vacuna = 'INFLUENZA',
        @Dosis = 1;
END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS NumeroError,
           ERROR_MESSAGE() AS MensajeError,
           @@TRANCOUNT AS TransaccionesAbiertas;
END CATCH;

SELECT Stock AS StockInfluenza
FROM dbo.StockVacuna
WHERE EstablecimientoId = 1
AND Vacuna = 'INFLUENZA';
GO

--prueba4
--1)
EXEC dbo.usp_DispensarVacuna
    @PacienteId = 2,
    @EstablecimientoId = 1,
    @Vacuna = 'INFLUENZA',
    @Dosis = 2;
--2)
EXEC dbo.usp_DispensarVacuna
    @PacienteId = 2,
    @EstablecimientoId = 1,
    @Vacuna = 'INFLUENZA',
    @Dosis = 1,
    @SimularFalloAlerta = 1;

SELECT Vacuna, Stock
FROM dbo.StockVacuna
WHERE EstablecimientoId = 1
ORDER BY Vacuna;

SELECT AlertaStockId, StockVacunaId, StockRestante
FROM dbo.AlertaStock
ORDER BY AlertaStockId;

SELECT COUNT(*) AS Dispensaciones
FROM dbo.DispensacionVacuna;