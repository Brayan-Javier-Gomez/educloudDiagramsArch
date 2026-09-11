# Modelado de Dominio — EduCloud
### Bounded contexts, context map y agregados (DDD)

> Versión 1.0 · Complementa `educloud.dsl` (diagrama de contenedores/microservicios) y `contratos-api-EduCloud.md`. Área: análisis de dominio y diseño táctico (DDD).

---

## 1. Método: cómo mapear los bounded contexts

1. **Encontrar la terminología propia.** Cada contexto usa términos con significado único. Ej.: *"Matrícula"* (inscripción + cupo + pago) ≠ *"Catálogo"* (curso como oferta de contenido) ≠ *"Evaluaciones"* (curso como consigna calificable). Si un mismo concepto cambia de reglas o de "año escolar", probablemente es otra frontera.
2. **Identificar subdominios** para priorizar esfuerzo y arquitectura:
   - **Core** (ventaja competitiva): Evaluaciones, Clases en Vivo, Matrícula.
   - **Supporting** (soportan al core): Catálogo, Contenido/Media, Analytics.
   - **Generic** (estándar, conviene comprar/reusar): Identidad/SSO, Notificaciones, Pagos.
3. **Trazar los flujos de negocio** (Event Storming). Donde un evento cruza una frontera, hay una integración. En EduCloud el patrón dominante es **eventos de dominio vía Kafka** + **Anti-Corruption Layers** contra sistemas externos.
4. **Aislar datos.** Una base de datos (o esquema) por contexto; nunca tablas compartidas entre contextos. Reflejado en `educloud.dsl`: cada microservicio tiene su propia BD.

La regla de oro: *un bounded context es la frontera donde un modelo de dominio es válido sin ambigüedad*, delimitada por lenguaje universal, equipo/cambio y consistencia.

---

## 2. Mapa de bounded contexts de EduCloud

| # | Bounded Context | Subdominio | Microservicio (contenedor) | Datos propios |
|---|---|---|---|---|
| 1 | Identidad y Accesos | Generic | Auth & Identity Service | credenciales, consentimientos, auditoría |
| 2 | Catálogo de Cursos | Supporting | Catálogo & Cursos | cursos, contenidos, materiales |
| 3 | Matrícula | Core | Matrícula Service | inscripciones, cupos, pagos |
| 4 | Clases en Vivo | Core | Clases en Vivo | salas, sesiones, grabaciones |
| 5 | Contenido/Media | Supporting | Media Service | videos on-demand (VOD) |
| 6 | Evaluaciones | Core | Evaluaciones Service | exámenes, intentos, calificaciones |
| 7 | Notificaciones | Generic | Notificaciones Service | canales, plantillas, preferencias |
| 8 | Analytics & Reportes | Supporting | Analytics Service | métricas académicas, auditoría |

### Eventos que cruzan las fronteras

| Evento (Kafka/Published Language) | Publica (BC productor) | Consumen (BC consumidores) |
|---|---|---|
| `usuario.registrado` | Identidad y Accesos | Analytics |
| `curso.publicado` | Catálogo de Cursos | Matrícula, Analytics |
| `inscripcion.realizada` | Matrícula | Evaluaciones (habilita intentos), Analytics |
| `clase.iniciada` | Clases en Vivo | Notificaciones, Analytics |
| `evaluacion.calificada` | Evaluaciones | Notificaciones, Analytics |

### Context map (relaciones entre contextos)

- **Publisher/Subscriber** (productor → consumidor): la relación por defecto en EduCloud. El contrato de eventos es un **Published Language** versionado (p. ej. Avro + Schema Registry en Kafka): el productor no conoce a sus consumidores.
- **Anti-Corruption Layer (ACL)**:
  - Matrícula → Pasarela de Pagos (traduce el modelo del banco al lenguaje del contexto).
  - Identidad → IdP externo (SAML/OIDC).
  - Clases en Vivo → SFU WebRTC (protocolo de señalización traducido al dominio).
- **Shared Kernel** evitado: no se comparten tablas ni objetos entre contextos; la única comunicación es eventos + APIs del gateway.

---

## 3. Agregados

Un agregado es un **grafo de objetos que se modifica de forma atómica**, con un **Agregado Raíz** que garantiza las *invariantes*. Reglas del diseño:

- Referenciar otros agregados **solo por ID** (nunca navegación de objeto).
- Guardar/leer el agregado completo por su **Repositorio**.
- Publicar **un evento por agregado** al confirmar el cambio en la transacción de mayorista (patrón *event-commit*).

### 3.1 BC Evaluaciones — `Evaluacion` y `IntentoDeEvaluacion`

Dos agregados separados a propósito: la consigna la modifica el docente; el intento lo crea el estudiante a alto volumen y con otras reglas. Se referencian por ID.

```
Agregado: Evaluacion
  Raíz: Evaluacion            (EvaluacionId)
  Entidades: List<Pregunta>                 // la consigna completa
  Value Objects: FechaLimite, TipoEvaluacion, PuntosPorPregunta
  Invariantes:
    - PuntajeMaximo = Σ puntos de sus Preguntas (siempre consistente)
    - No se puede editar la consigna con Intentos en CALIFICANDO/CALIFICADO
    - fechaLimite dentro del período del curso
  Referencia a otros agregados: List<IntentoId>   // solo IDs

Agregado: IntentoDeEvaluacion
  Raíz: IntentoDeEvaluacion   (IntentoId)
  Value Objects: Respuestas, EstadoIntento, Calificacion
  Invariantes:
    - El estudiante no excede IntentosMaximos de la Evaluacion
      (consultando Evaluacion por EvaluacionId)
    - Solo se califica un Intento en estado ENTREGADO/CALIFICANDO
    - Idempotencia: misma Idempotency-Key ⇒ mismo IntentoId
    - Al pasar a CALIFICADO se persiste Calificacion y se publica
      evaluacion.calificada
```

### 3.2 BC Matrícula — `Matricula`

```
Agregado: Matricula
  Raíz: Matricula             (MatriculaId)
  Value Objects: EstadoMatricula, PeriodoAcademico, Cupo
  Invariantes:
    - Un Estudiante no se matricula dos veces en el mismo Curso en el
      mismo PeriodoAcademico
    - La Matricula se confirma solo si quedan Cupos disponibles (valida
      contra el agregado CuposDelCurso por CursoId)
    - Requiere el pago confirmado por el ACL de Pasarela de Pagos
  Eventos: inscripcion.realizada (al confirmar) · fuera-de-cupo a Catálogo
```

### 3.3 BC Clases en Vivo — `ClaseEnVivo`

```
Agregado: ClaseEnVivo
  Raíz: ClaseEnVivo           (ClaseEnVivoId)
  Entidades: List<SesionEnVivo>            // una clase puede tener varias sesiones
  Value Objects: SalaWebRTC (id de sala del SFU), RangoHorario, Grabacion
  Invariantes:
    - No comparte SalaWebRTC con otra ClaseEnVivo en el mismo RangoHorario
    - Solo el Docente del curso inicia la clase
    - Un participante requiere estar Matriculado (verifica por EstudianteId
      contra Matrícula vía evento/API)
  Eventos: clase.iniciada (al encender la sala) · clase.grabada (al cerrarla)
```

### 3.4 BC Catálogo de Cursos — `Curso`

```
Agregado: Curso
  Raíz: Curso                 (CursoId)
  Entidades: List<EdicionDeCurso>          // cohortes/años
  Value Objects: Titulo, Descripcion, DocentesIds, EstadoPublicacion
  Invariantes:
    - El Curso no se publica sin al menos un Docente asignado
    - EstadoPublicacion solo pasa BORRADOR → PUBLICADO (no retrocede
      si existen Matriculas)
  Referencia a otros agregados: List<MatriculaId>, List<EvaluacionId>  // IDs
  Eventos: curso.publicado (al cambiar a PUBLICADO)
```

---

## 4. Reglas transversales del diseño táctico

| Regla | Justificación en EduCloud |
|---|---|
| **Un repositorio por agregado raíz** | Lee/escribe el grafo completo; los autores del dominio (docente, estudiante) no lo violan. |
| **No tablas compartidas entre contextos** | Sin acoplamiento de datos; cada BD es privada de su microservicio (ver `educloud.dsl`). |
| **Idempotencia en escritura** | `Idempotency-Key` en `IntentoDeEvaluacion` y `Matricula` para reintentos en picos de 200k usuarios. |
| **Eventos versionados (Published Language)** | `estructura.avro` en Schema Registry; permite evolucionar consumidores sin tocar productores. |
| **Consistencia eventual entre contextos** | La transacción es atómica solo dentro del agregado; el resto viaja por eventos (`evaluacion.calificada` → notificación/analytics). |
| **Invariantes visibles en el código** | Cada invariante queda explícita en el método del agregado raíz, nunca en la capa de aplicación. |
| **Trazabilidad y privacidad (GDPR/FERPA)** | Los eventos no transportan PII; solo IDs. La PII vive en su contexto (Identidad) y se resuelve bajo autorización. |

---

## 5. Correspondencia con la arquitectura

```
Bounded Context  →  Microservicio (contenedor en educloud.dsl)  →  Agregado(s) raíz
Evaluaciones     →  Evaluaciones Service                         →  Evaluacion, IntentoDeEvaluacion
Matrícula        →  Matrícula Service                            →  Matricula, CuposDelCurso
Clases en Vivo   →  Clases en Vivo                               →  ClaseEnVivo
Catálogo         →  Catálogo & Cursos                            →  Curso
Identidad        →  Auth & Identity Service                      →  Usuario (AGREGADO FINAL: consentimientos)
```

Este mapeo valida la decisión de arquitectura del contrato inicial: cada bounded context = un microservicio con su BD, comunicado por eventos; los agregados garantizan que los invariantes de negocio (cupo, calificación, idempotencia) se cumplen dentro de cada frontera, sin impacto entre componentes.