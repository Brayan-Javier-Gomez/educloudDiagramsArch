# EduCloud — Bounded Contexts y Agregados (Ejemplo)

Resultado del modelado DDD para la plataforma EduCloud: mapeo de bounded contexts y definición de agregados. Complementa `educloud.dsl` (diagrama de contenedores) y `contratos-api-EduCloud.md`.

---

## 1. Mapa de bounded contexts de EduCloud

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

| Evento (Kafka / Published Language) | Publica (BC productor) | Consumen (BC consumidores) |
|---|---|---|
| `usuario.registrado` | Identidad y Accesos | Analytics |
| `curso.publicado` | Catálogo de Cursos | Matrícula, Analytics |
| `inscripcion.realizada` | Matrícula | Evaluaciones (habilita intentos), Analytics |
| `clase.iniciada` | Clases en Vivo | Notificaciones, Analytics |
| `evaluacion.calificada` | Evaluaciones | Notificaciones, Analytics |

### Context map (relaciones entre contextos)

- **Publisher/Subscriber** (productor → consumidor): relación por defecto en EduCloud. El contrato de eventos es un Published Language versionado (Avro + Schema Registry en Kafka); el productor no conoce a sus consumidores.
- **Anti-Corruption Layer (ACL)**:
  - Matrícula → Pasarela de Pagos (traduce el modelo del banco al lenguaje del contexto).
  - Identidad → IdP externo (SAML/OIDC).
  - Clases en Vivo → SFU WebRTC (señalización traducida al dominio).
- **Shared Kernel evitado**: no se comparten tablas ni objetos entre contextos; la única comunicación es eventos + APIs del gateway.

---

## 2. Agregado del BC Evaluaciones: `Evaluacion` y `IntentoDeEvaluacion`

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

### Otros agregados definidos

```
Agregado: Matricula                    // BC Matrícula (Core)
  Raíz: Matricula          (MatriculaId)
  Value Objects: EstadoMatricula, PeriodoAcademico, Cupo
  Invariantes:
    - Un Estudiante no se matricula dos veces en el mismo Curso en el
      mismo PeriodoAcademico
    - La Matricula se confirma solo si quedan Cupos disponibles
      (valida contra CuposDelCurso por CursoId)
    - Requiere el pago confirmado por el ACL de Pasarela de Pagos
  Eventos: inscripcion.realizada (al confirmar) · fuera-de-cupo a Catálogo

Agregado: ClaseEnVivo                  // BC Clases en Vivo (Core)
  Raíz: ClaseEnVivo        (ClaseEnVivoId)
  Entidades: List<SesionEnVivo>            // una clase puede tener varias sesiones
  Value Objects: SalaWebRTC, RangoHorario, Grabacion
  Invariantes:
    - No comparte SalaWebRTC con otra ClaseEnVivo en el mismo RangoHorario
    - Solo el Docente del curso inicia la clase
    - Un participante debe estar Matriculado (verifica por EstudianteId
      contra Matrícula vía evento/API)
  Eventos: clase.iniciada (al encender la sala) · clase.grabada (al cerrarla)

Agregado: Curso                        // BC Catálogo de Cursos (Supporting)
  Raíz: Curso              (CursoId)
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

## 3. Correspondencia con la arquitectura (`educloud.dsl`)

```
Bounded Context  →  Microservicio (contenedor)  →  Agregado(s) raíz
Evaluaciones     →  Evaluaciones Service        →  Evaluacion, IntentoDeEvaluacion
Matrícula        →  Matrícula Service           →  Matricula, CuposDelCurso
Clases en Vivo   →  Clases en Vivo              →  ClaseEnVivo
Catálogo         →  Catálogo & Cursos           →  Curso
Identidad        →  Auth & Identity Service     →  Usuario
Notificaciones   →  Notificaciones Service      →  (sin agregado propio: contexto reactivo)
Analytics        →  Analytics Service           →  (modelo de lectura / sin operaciones de dominio)
```

Cada bounded context = un microservicio con su BD, comunicado por eventos. Los agregados garantizan los invariantes de negocio (cupo, calificación, idempotencia) dentro de cada frontera, sin impacto entre componentes.