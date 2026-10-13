-- =====================================================================
-- Evaluación Individual de Laboratorio - Segunda Convocatoria 2025-2026
-- Tienda Online (MySQL 8.0.16+, necesario para que se apliquen los CHECK)
-- Ejecutar DESPUÉS de creacionTablas.sql y poblarBd.sql
-- =====================================================================

DROP TABLE IF EXISTS LineasRecepcion;
DROP TABLE IF EXISTS Recepciones;

-- =====================================================================
-- 1. CREACIÓN DE TABLAS (1,5 puntos)
-- =====================================================================

CREATE TABLE Recepciones (
    id INT PRIMARY KEY AUTO_INCREMENT,
    fechaRecepcion DATE NOT NULL,
    comentarios TEXT,                      -- opcional (NULL) y sin límite fijo de caracteres
    pedidoId INT NOT NULL,
    FOREIGN KEY (pedidoId) REFERENCES Pedidos(id)
        ON DELETE CASCADE
        ON UPDATE CASCADE
);

CREATE TABLE LineasRecepcion (
    id INT PRIMARY KEY AUTO_INCREMENT,
    recepcionId INT NOT NULL,
    lineaPedidoId INT NOT NULL,
    cantidad INT NOT NULL,
    CONSTRAINT chk_cantidad_recepcion_positiva CHECK (cantidad > 0),
    FOREIGN KEY (recepcionId) REFERENCES Recepciones(id)
        ON DELETE CASCADE
        ON UPDATE CASCADE,
    FOREIGN KEY (lineaPedidoId) REFERENCES LineasPedido(id)
        ON DELETE CASCADE
        ON UPDATE CASCADE,
    UNIQUE (recepcionId, lineaPedidoId)
);

-- =====================================================================
-- 2. CONSULTAS SQL (3,5 puntos)
-- =====================================================================

-- 2.1 (1,5 puntos)
-- Pedidos al menos parcialmente recepcionados cuya PRIMERA recepción
-- se produjo más de una semana después de realizarse el pedido.
SELECT u.nombre, p.id AS pedidoId, p.fechaRealizacion
FROM Pedidos p
    INNER JOIN Clientes c ON p.clienteId = c.id
    INNER JOIN Usuarios u ON c.usuarioId = u.id
    INNER JOIN Recepciones r ON r.pedidoId = p.id
GROUP BY p.id, u.nombre, p.fechaRealizacion
HAVING DATEDIFF(MIN(r.fechaRecepcion), p.fechaRealizacion) > 7;

-- 2.2 (2 puntos)
-- Clientes con más de 500 euros en pedidos que aún no han comenzado
-- a recepcionarse (pedidos sin ninguna recepción).
SELECT c.id AS clienteId,
       u.nombre,
       SUM(lp.unidades * lp.precio) AS totalSinRecepcionar
FROM Clientes c
    INNER JOIN Usuarios u ON c.usuarioId = u.id
    INNER JOIN Pedidos p ON p.clienteId = c.id
    INNER JOIN LineasPedido lp ON lp.pedidoId = p.id
WHERE NOT EXISTS (SELECT 1 FROM Recepciones r WHERE r.pedidoId = p.id)
GROUP BY c.id, u.nombre
HAVING SUM(lp.unidades * lp.precio) > 500;

-- =====================================================================
-- 3. PROCEDIMIENTO (2,5 puntos)
-- =====================================================================

DROP PROCEDURE IF EXISTS RecepcionarPedidoCompleto;

DELIMITER //

CREATE PROCEDURE RecepcionarPedidoCompleto(IN p_pedidoId INT)
BEGIN
    DECLARE v_lineasFisicas INT;
    DECLARE v_recepcionId INT;

    -- Si algo falla, se deshace todo y se propaga el error original
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    START TRANSACTION;

    -- Número de líneas del pedido que son de productos físicos (no digitales)
    SELECT COUNT(*) INTO v_lineasFisicas
    FROM LineasPedido lp
        INNER JOIN Productos pr ON pr.id = lp.productoId
        INNER JOIN TiposProducto tp ON tp.id = pr.tipoProductoId
    WHERE lp.pedidoId = p_pedidoId
      AND tp.nombre <> 'Digitales';

    -- Pedido compuesto solamente por productos digitales
    IF v_lineasFisicas = 0 THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'No se permite recepcionar pedidos de productos digitales.';
    END IF;

    -- Cabecera de la recepción
    INSERT INTO Recepciones (fechaRecepcion, comentarios, pedidoId)
    VALUES (CURDATE(), 'Recepción completa creada automáticamente', p_pedidoId);

    SET v_recepcionId = LAST_INSERT_ID();

    -- Una línea de recepción por cada línea física del pedido, con todas sus unidades
    INSERT INTO LineasRecepcion (recepcionId, lineaPedidoId, cantidad)
    SELECT v_recepcionId, lp.id, lp.unidades
    FROM LineasPedido lp
        INNER JOIN Productos pr ON pr.id = lp.productoId
        INNER JOIN TiposProducto tp ON tp.id = pr.tipoProductoId
    WHERE lp.pedidoId = p_pedidoId
      AND tp.nombre <> 'Digitales';

    COMMIT;
END //

-- =====================================================================
-- 4. TRIGGER (2,5 puntos)
-- =====================================================================

DROP TRIGGER IF EXISTS asegurar_recepcion_correcta //

CREATE TRIGGER asegurar_recepcion_correcta
BEFORE INSERT ON LineasRecepcion
FOR EACH ROW
BEGIN
    DECLARE v_tipo VARCHAR(255);
    DECLARE v_unidadesPedidas INT;
    DECLARE v_unidadesRecepcionadas INT;

    -- Tipo del producto y unidades pedidas de la línea de pedido recepcionada
    SELECT tp.nombre, lp.unidades
    INTO v_tipo, v_unidadesPedidas
    FROM LineasPedido lp
        INNER JOIN Productos pr ON pr.id = lp.productoId
        INNER JOIN TiposProducto tp ON tp.id = pr.tipoProductoId
    WHERE lp.id = NEW.lineaPedidoId;

    -- No se pueden recepcionar productos digitales
    IF v_tipo = 'Digitales' THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'No se permite recepcionar productos digitales.';
    END IF;

    -- Unidades ya recepcionadas de esa línea en recepciones anteriores
    SELECT COALESCE(SUM(cantidad), 0)
    INTO v_unidadesRecepcionadas
    FROM LineasRecepcion
    WHERE lineaPedidoId = NEW.lineaPedidoId;

    -- No se pueden recepcionar más unidades de las pedidas
    IF v_unidadesRecepcionadas + NEW.cantidad > v_unidadesPedidas THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'No se pueden recepcionar más unidades de las pedidas.';
    END IF;
END //

DELIMITER ;

-- =====================================================================
-- PRUEBAS (opcional, descomentar para probar)
-- =====================================================================
-- -- Pedido 1: 1 smartphone, 2 camisetas, 1 libro electrónico (digital)
-- CALL RecepcionarPedidoCompleto(1);   -- OK: recepciona smartphone y camisetas, ignora el libro
-- CALL RecepcionarPedidoCompleto(1);   -- ERROR del trigger: más unidades de las pedidas
-- CALL RecepcionarPedidoCompleto(3);   -- OK: todo físico
--
-- -- Error de cantidad positiva
-- INSERT INTO Recepciones (fechaRecepcion, pedidoId) VALUES ('2024-10-20', 2);
-- INSERT INTO LineasRecepcion (recepcionId, lineaPedidoId, cantidad)
--     VALUES (LAST_INSERT_ID(), 8, 0); -- ERROR chk_cantidad_recepcion_positiva
--
-- -- Pedido solo digital: crear uno y llamar al procedimiento -> error de digitales
--
-- -- Prueba de 2.1: recepción 14 días tarde del pedido 2 (realizado 2024-10-02)
-- INSERT INTO Recepciones (fechaRecepcion, pedidoId) VALUES ('2024-10-16', 2);
