# Contratos de API — EduCloud
### REST, GraphQL y gRPC para el dominio de Evaluaciones

> Versión 1.0 · Alineado a los NFR de EduCloud (200k concurrentes, latencia < 2 s en evaluaciones, seguridad GDPR/FERPA, antitransparencia y eventos asíncronos vía Kafka).

---

## 1. Contexto y decisiones

| Decisión | Justificación |
|---|---|
| El contrato se define sobre el dominio **Evaluaciones** (Enviar intento → Calificar → Notificar). | Es el flujo crítico del ejercicio anterior (Evaluaciones → Kafka → Notificaciones). |
| REST y GraphQL expuestos por el **API Gateway** (HTTPS/JSON); gRPC interna o entre servicios (HTTP/2). | El gateway normaliza auth, rate limiting y versionado; gRPC no necesita exponerse a clientes web directos. |
| Operación de escritura **idempotente** con `Idempotency-Key`. | Evita doble calificación si el cliente reintenta en picos masivos. |
| Tras confirmar la escritura se **publica el evento** `evaluacion.calificada` en Kafka. | El contrato síncrono solo responde la operación; el fan-out (notificaciones, analytics) es asíncrono. |
| Errores normalizados (RFC 7807 REST, `errors[].extensions.code` en GraphQL, status codes en gRPC). | Facilita consumidores y cumple observabilidad/auditoría. |

**Autenticación/autorización**
- REST / GraphQL: header `Authorization: Bearer <JWT>` (emitido por *Auth & Identity Service*; roles `estudiante`, `docente`, `admin`).
- gRPC: metadata `authorization: Bearer <JWT>`.
- PII (GDPR/FERPA): listado de resultados solo del propio estudiante o del docente/admin del curso; los logs no exponen datos personales.

**Paginar resultados**: cursor opaco + `limit` (REST), conexiones con `edges/cursor` (GraphQL), server-streaming con offsets de cursor (gRPC).

---

## 2. Contrato REST (OpenAPI 3.1)

```yaml
openapi: 3.1.0
info:
  title: EduCloud Evaluaciones API
  version: v1
servers:
  - url: https://api.educloud.com/api/v1
security:
  - bearerAuth: []
paths:
  /evaluaciones/{evaluacionId}/intentos:
    post:
      operationId: enviarIntento
      summary: Envía un intento de evaluación (calificable)
      parameters:
        - name: Idempotency-Key
          in: header
          required: true
          schema: { type: string, format: uuid }
      requestBody:
        required: true
        content:
          application/json:
            schema: { $ref: '#/components/schemas/EnviarIntentoRequest' }
      responses:
        '201':
          description: Intento creado y encolado para calificación
          content:
            application/json:
              schema: { $ref: '#/components/schemas/Intento' }
        '202':
          description: Intento calificado de forma asíncrona (se notificará por evento)
        '400': { $ref: '#/components/responses/Error' }
        '401': { $ref: '#/components/responses/Error' }
        '404': { $ref: '#/components/responses/Error' }
        '409': { $ref: '#/components/responses/Error' }
        '429': { $ref: '#/components/responses/Error' }
  /intentos/{intentoId}:
    get:
      operationId: obtenerIntento
      parameters:
        - { name: intentoId, in: path, required: true, schema: { type: string } }
      responses:
        '200':
          description: Detalle del intento
          content:
            application/json:
              schema: { $ref: '#/components/schemas/Intento' }
        '404': { $ref: '#/components/responses/Error' }
  /estudiantes/{estudianteId}/resultados:
    get:
      operationId: listarResultados
      parameters:
        - { name: estudianteId, in: path, required: true, schema: { type: string } }
        - { name: cursor, in: query, schema: { type: string } }
        - { name: limit, in: query, schema: { type: integer, default: 50, maximum: 100 } }
      responses:
        '200':
          description: Lista paginada de resultados
          content:
            application/json:
              schema: { $ref: '#/components/schemas/ResultadoPagina' }
components:
  securitySchemes:
    bearerAuth: { type: http, scheme: bearer, bearerFormat: JWT }
  schemas:
    EnviarIntentoRequest:
      type: object
      required: [evaluacionId, respuestas]
      properties:
        evaluacionId: { type: string, format: uuid }
        respuestas:
          type: array
          items: { $ref: '#/components/schemas/Respuesta' }
    Respuesta:
      type: object
      required: [preguntaId, valor]
      properties:
        preguntaId: { type: string, format: uuid }
        valor: { type: string }
    Intento:
      type: object
      properties:
        id: { type: string, format: uuid }
        evaluacionId: { type: string, format: uuid }
        estudianteId: { type: string, format: uuid }
        estado: { $ref: '#/components/schemas/EstadoIntento' }
        entregadoEn: { type: string, format: date-time }
        calificacion: { $ref: '#/components/schemas/Calificacion' }
    EstadoIntento: { type: string, enum: [ENTREGADO, CALIFICANDO, CALIFICADO] }
    Calificacion:
      type: object
      properties:
        obtenida: { type: number }
        puntajeMaximo: { type: number }
        devolucion: { type: string }
    ResultadoPagina:
      type: object
      properties:
        items: { type: array, items: { $ref: '#/components/schemas/Intento' } }
        nextCursor: { type: string, nullable: true }
  responses:
    Error:
      description: Error (RFC 7807, application/problem+json)
      content:
        application/problem+json:
          schema:
            type: object
            properties:
              type: { type: string }
              title: { type: string }
              status: { type: integer }
              detail: { type: string }
              traceId: { type: string }
```

### Ejemplo REST

```
POST /api/v1/evaluaciones/3fa85f64-5717-4562-b3fc-2c963f66afa6/intentos
Authorization: Bearer <jwt>
Idempotency-Key: 745e5e15-2fd1-4e8a-a4b7-4a2f9e0d12ab
Content-Type: application/json

{
  "respuestas": [
    { "preguntaId": "4a2f9e0d-12ab-4e8a-a4b7-745e5e152fd1", "valor": "2026-09-10T10:00:00Z" },
    { "preguntaId": "6b3c...", "valor": "B" }
  ]
}
```

```
HTTP/1.1 201 Created
Content-Type: application/json

{
  "id": "9c8b7a6f-0001-4000-8000-000000000001",
  "evaluacionId": "3fa85f64-5717-4562-b3fc-2c963f66afa6",
  "estudianteId": "c6f3bd45-7e1a-4b2e-9f0d-2c963f66afa6",
  "estado": "CALIFICANDO",
  "entregadoEn": "2026-09-10T10:00:03.123Z"
}
```

Tras esto se publica en Kafka `evaluacion.calificada` y *Notificaciones Service* avisa al estudiante (flujo asíncrono, no forma parte de este contrato síncrono).

---

## 3. Contrato GraphQL (SDL)

```graphql
type Evaluacion {
  id: ID!
  titulo: String!
  tipo: TipoEvaluacion!
  puntajeMaximo: Float!
  fechaLimite: DateTime
}

enum TipoEvaluacion { PRACTICA PARCIAL FINAL PROYECTO }

type Calificacion {
  obtenida: Float!
  puntajeMaximo: Float!
  devolucion: String
}

enum EstadoIntento { ENTREGADO CALIFICANDO CALIFICADO }

type Intento {
  id: ID!
  evaluacion: Evaluacion!
  estudianteId: ID!
  estado: EstadoIntento!
  entregadoEn: DateTime!
  calificacion: Calificacion
}

type ResultadoConexion {
  edges: [IntentoEdge!]!
  pageInfo: PageInfo!
}

type IntentoEdge {
  node: Intento!
  cursor: String!
}

type PageInfo {
  endCursor: String
  hasNextPage: Boolean!
}

input RespuestaInput {
  preguntaId: ID!
  valor: String!
}

type Query {
  evaluacion(id: ID!): Evaluacion
  intento(id: ID!): Intento
  resultados(estudianteId: ID!, first: Int = 50, after: String): ResultadoConexion
}

type Mutation {
  enviarIntento(
    evaluacionId: ID!
    idempotencyKey: String!
    respuestas: [RespuestaInput!]!
  ): Intento!
}

type Subscription {
  intentoCalificado(estudianteId: ID!): Intento!
}
```

### Ejemplo de mutation (equivalente al POST REST)

```graphql
mutation EnviarIntento($evaluacionId: ID!, $key: String!, $respuestas: [RespuestaInput!]!) {
  enviarIntento(evaluacionId: $evaluacionId, idempotencyKey: $key, respuestas: $respuestas) {
    id
    estado
    entregadoEn
    calificacion { obtenida puntajeMaximo }
  }
}
```

```json
{
  "query": "...",
  "variables": {
    "evaluacionId": "3fa85f64-5717-4562-b3fc-2c963f66afa6",
    "key": "745e5e15-2fd1-4e8a-a4b7-4a2f9e0d12ab",
    "respuestas": [
      { "preguntaId": "4a2f9e0d-12ab-4e8a-a4b7-745e5e152fd1", "valor": "2026-09-10T10:00:00Z" }
    ]
  }
}
```

**Errores GraphQL** (códigos equivalentes a los HTTP del REST):

```json
{
  "errors": [
    {
      "message": "La evaluación no existe",
      "extensions": { "code": "NOT_FOUND", "traceId": "abc-123" }
    }
  ]
}
```

> Nota de rendimiento: evitar N+1 resolviendo `evaluacion` desde `Intento` con DataLoader; el contrato expone solo los datos necesarios por consumer y el gateway limita profundidad de query.

---

## 4. Contrato gRPC (proto v3)

```proto
syntax = "proto3";

package educloud.evaluaciones.v1;

import "google/protobuf/timestamp.proto";

service EvaluacionesService {
  // Envía un intento (idempotente por idempotency_key).
  rpc EnviarIntento(EnviarIntentoRequest) returns (EnviarIntentoResponse);
  // Obtiene un intento por id.
  rpc ObtenerIntento(ObtenerIntentoRequest) returns (Intento);
  // Lista resultados de un estudiante usando server-streaming.
  rpc ListarResultados(ListarResultadosRequest) returns (stream Resultado);
}

enum EstadoIntento {
  ESTADO_INTENTO_UNSPECIFIED = 0;
  ENTREGADO = 1;
  CALIFICANDO = 2;
  CALIFICADO = 3;
}

message Respuesta {
  string pregunta_id = 1;
  string valor = 2;
}

message EnviarIntentoRequest {
  string idempotency_key = 1;
  string evaluacion_id = 2;
  repeated Respuesta respuestas = 3;
}

message EnviarIntentoResponse {
  Intento intento = 1;
  bool calificado = 2; // false => se calificará async y se notificará por evento
}

message ObtenerIntentoRequest {
  string intento_id = 1;
}

message Calificacion {
  double obtenida = 1;
  double puntaje_maximo = 2;
  string devolucion = 3;
}

message Intento {
  string id = 1;
  string evaluacion_id = 2;
  string estudiante_id = 3;
  EstadoIntento estado = 4;
  google.protobuf.Timestamp entregado_en = 5;
  Calificacion calificacion = 6;
  string version = 7; // optimistic locking / condiciones de concurrencia
}

message Resultado {
  string cursor = 1;
  Intento intento = 2;
}

message ListarResultadosRequest {
  string estudiante_id = 1;
  string cursor = 2;
  int32 limit = 3; // default 50, máx 100
}
```

### Invocación

```bash
grpcurl -H "authorization: Bearer <jwt>" \
  -d '{"idempotency_key":"745e5e15-2fd1-4e8a-a4b7-4a2f9e0d12ab","evaluacion_id":"3fa85f64-5717-4562-b3fc-2c963f66afa6","respuestas":[{"pregunta_id":"4a2f9e0d-12ab-4e8a-a4b7-745e5e152fd1","valor":"2026-09-10T10:00:00Z"}]}' \
  educloud.internal:50051 educloud.evaluaciones.v1.EvaluacionesService/EnviarIntento
```

Política de llamada: deadline 2 s por RPC (restringido por el SLA de evaluaciones), retry solo en códigos transitorios (`UNAVAILABLE`, `DEADLINE_EXCEEDED`) con backoff exponencial y máx 3 reintentos; respetar la `idempotency_key` para reintentos seguros.

---

## 5. Equivalencias entre contratos

| Operación de negocio | REST | GraphQL | gRPC |
|---|---|---|---|
| Enviar intento | `POST /evaluaciones/{id}/intentos` (201/202) | `mutation enviarIntento` | `EnviarIntento` |
| Obtener intento | `GET /intentos/{id}` (200) | `query intento(id:)` | `ObtenerIntento` |
| Listar resultados | `GET /estudiantes/{id}/resultados?cursor=&limit=` (200) | `query resultados(estudianteId:, first:, after:)` | `ListarResultados` (server-streaming) |
| Pub de resultado (async) | Evento `evaluacion.calificada` (Kafka) | `subscription intentoCalificado` | (evento Kafka; no es RPC) |

### Mapa de errores

| REST (RFC 7807 `status`) | GraphQL `extensions.code` | gRPC status | Significado |
|---|---|---|---|
| 400 | `BAD_REQUEST` | `INVALID_ARGUMENT` | Validación de request |
| 401 | `UNAUTHENTICATED` | `UNAUTHENTICATED` | JWT ausente/inválido/vencido |
| 403 | `FORBIDDEN` | `PERMISSION_DENIED` | Sin rol para la operación (GDPR/FERPA) |
| 404 | `NOT_FOUND` | `NOT_FOUND` | Recurso inexistente |
| 409 | `CONFLICT` / `ALREADY EXISTS` | `ALREADY_EXISTS` | Idempotency-Key repetida con otro payload |
| 429 | `RATE_LIMITED` | `RESOURCE_EXHAUSTED` | Rate limit / cupo por pico |
| 500 | `INTERNAL` | `INTERNAL` | Error no mapeado |
| 503 | `UNAVAILABLE` | `UNAVAILABLE` | Servicio escalando / degradado |

---

## 6. Requisitos transversales (NFR)

- **Desempeño**: latencia objetivo < 2 s para el round-trip síncrono de `EnviarIntento`; gRPC con HTTP/2 + protobuf para el bus interno; DataLoader/paginación por cursor para evitar lecturas pesadas en GraphQL.
- **Escalabilidad (200k concurrentes)**: todos los servicios *stateless*; idempotencia en escritura para absorber reintentos de picos; auto-scaling del API Gateway y particionado de Kafka por `evaluacion_id`.
- **Seguridad/privacidad**: TLS end-to-end, JWT con roles, PII restringida por rol, trazas sin datos personales (GDPR/FERPA), rate limiting por consumidor.
- **Mantenibilidad**: el contrato se versiona por compatibilidad (`/v1`, paquete `.v1`, breaking changes = major); el evento `evaluacion.calificada` desacopla calificación de notificación/analytics.