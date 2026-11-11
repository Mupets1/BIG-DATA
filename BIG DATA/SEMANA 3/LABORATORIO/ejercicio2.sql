USE BDDataSaludTema01;
GO
--ejercisio02

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
