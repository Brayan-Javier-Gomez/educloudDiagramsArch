workspace "EduCloud" "Arquitectura de contenedores con microservicios y eventos (2026)" {

    !identifiers hierarchical

    model {

        student = person "Estudiante" "Se matricula, consume clases en vivo y presenta evaluaciones."
        teacher = person "Docente" "Crea cursos, imparte clases en vivo y diseña evaluaciones."
        admin = person "Administrador" "Gestiona catálogo, matrículas y reportes institucionales."

        idp = softwareSystem "Proveedor de Identidad" "SSO institucional (SAML/OIDC) para EdoCloud." "Microsoft Entra ID / Keycloak"
        sfu = softwareSystem "Plataforma SFU WebRTC" "Escala audio/video en vivo (latencia < 300 ms)." "LiveKit / Janus"
        payments = softwareSystem "Pasarela de Pagos" "Procesa pagos de matrículas." "Stripe / Adyen"

        educloud = softwareSystem "EduCloud" "Plataforma educativa con microservicios y comunicación por eventos." "Microservicios + Kafka" {

            group "Fachada" {
                webApp = container "Portal Web" "SPA para estudiantes, docentes y administradores." "React"
                apiGateway = container "API Gateway" "Punto único de entrada, autenticación de tráfico, rate limiting." "Kong / NGINX"
            }

            group "Servicios de Dominio" {
                authService = container "Auth & Identity Service" "Autenticación, emisión de JWT, MFA y auditoría de accesos." "Go"
                catalogService = container "Catálogo & Cursos" "Gestión de cursos, contenidos y catálogo." "Node.js"
                enrollmentService = container "Matrícula Service" "Inscripciones, pagos y asignación de cupos." "Node.js"
                liveClassService = container "Clases en Vivo" "Orquesta salas WebRTC y gestiona sesiones en vivo." "Go"
                mediaService = container "Media Service" "Subida y distribución de videos on-demand." "Go"
                evalService = container "Evaluaciones Service" "Exámenes, calificación y anti-fraude." "Java/Spring"
                notifService = container "Notificaciones Service" "Envía correos, push y avisos." "Node.js"
                analyticsService = container "Analytics & Reportes" "Métricas académicas y auditoría GDPR/FERPA." "Python"
            }

            group "Datos, Eventos e Infraestructura" {
                userDB = container "Usuarios DB" "Credenciales, perfiles y consentimientos." "PostgreSQL" {
                    tags "Database"
                }
                courseDB = container "Cursos DB" "Catálogo, contenidos y materiales." "PostgreSQL" {
                    tags "Database"
                }
                enrollmentDB = container "Matrícula DB" "Inscripciones, pagos y cupos." "PostgreSQL" {
                    tags "Database"
                }
                evalDB = container "Evaluaciones DB" "Exámenes, intentos y calificaciones." "PostgreSQL" {
                    tags "Database"
                }
                analyticsDB = container "Analytics DB" "Modelo de datos para reportes." "ClickHouse" {
                    tags "Database"
                }
                eventBus = container "Event Bus" "Mensajería asíncrona entre microservicios." "Apache Kafka" {
                    tags "Event Bus"
                }
                cache = container "Cache Distribuida" "Caché de sesiones y datos calientes." "Redis"
                objectStore = container "Object Store" "Almacenamiento de videos y material." "Amazon S3" {
                    tags "Object Store"
                }
            }
        }

        student -> educloud.webApp "Usa la plataforma"
        teacher -> educloud.webApp "Usa la plataforma"
        admin -> educloud.webApp "Administra la plataforma"

        educloud.notifService -> student "Notifica resultados" "Email/Push"

        educloud.webApp -> educloud.apiGateway "Hace llamadas a la API" "HTTPS/JSON"
        educloud.webApp -> sfu "Transmite medios en tiempo real" "WebRTC"

        educloud.apiGateway -> educloud.authService "Autentica usuarios" "HTTPS/JSON"
        educloud.apiGateway -> educloud.catalogService "Consulta catálogo y cursos" "HTTPS/JSON"
        educloud.apiGateway -> educloud.enrollmentService "Matricula estudiantes" "HTTPS/JSON"
        educloud.apiGateway -> educloud.liveClassService "Gestiona clases en vivo" "HTTPS/JSON"
        educloud.apiGateway -> educloud.mediaService "Consulta contenidos on-demand" "HTTPS/JSON"
        educloud.apiGateway -> educloud.evalService "Gestiona evaluaciones" "HTTPS/JSON"
        educloud.apiGateway -> educloud.analyticsService "Consulta reportes" "HTTPS/JSON"

        educloud.authService -> educloud.userDB "Lee y escribe"
        educloud.catalogService -> educloud.courseDB "Lee y escribe"
        educloud.enrollmentService -> educloud.enrollmentDB "Lee y escribe"
        educloud.evalService -> educloud.evalDB "Lee y escribe"
        educloud.analyticsService -> educloud.analyticsDB "Lee y escribe"

        educloud.apiGateway -> educloud.cache "Lee y escribe datos calientes"
        educloud.authService -> educloud.cache "Almacena sesiones activas"
        educloud.authService -> idp "Valida credenciales" "SAML/OIDC"
        educloud.liveClassService -> sfu "Crea y orquesta salas" "WebRTC/Signal"
        educloud.liveClassService -> educloud.objectStore "Guarda grabaciones" "S3 API"
        educloud.mediaService -> educloud.objectStore "Almacena y lee videos" "S3 API"
        educloud.enrollmentService -> payments "Procesa pagos" "HTTPS/JSON"
        educloud.evalService -> educloud.cache "Almacena intentos en caliente"

        educloud.authService -> educloud.eventBus "Publica: usuario.registrado" {
            tags "Event"
        }
        educloud.catalogService -> educloud.eventBus "Publica: curso.publicado" {
            tags "Event"
        }
        educloud.enrollmentService -> educloud.eventBus "Publica: inscripcion.realizada" {
            tags "Event"
        }
        educloud.liveClassService -> educloud.eventBus "Publica: clase.iniciada" {
            tags "Event"
        }
        educloud.evalService -> educloud.eventBus "Publica: evaluacion.calificada" {
            tags "Event"
        }
        educloud.eventBus -> educloud.enrollmentService "Consume: curso.publicado" {
            tags "Event"
        }
        educloud.eventBus -> educloud.notifService "Consume eventos de dominio" {
            tags "Event"
        }
        educloud.eventBus -> educloud.analyticsService "Consume eventos para métricas" {
            tags "Event"
        }
    }

    views {

        systemContext educloud "ContextoEduCloud" {
            include *
            autoLayout lr
            title "EduCloud - Diagrama de Contexto de Sistemas"
        }

        container educloud "ContenedoresEduCloud" {
            include *
            autoLayout lr
            title "EduCloud - Diagrama de Contenedores (Microservicios)"
        }

        dynamic educloud "FlujoClaseEnVivo" "Flujo de inicio de una clase en vivo" {
            teacher -> educloud.webApp "Abre la clase desde el portal"
            educloud.webApp -> educloud.apiGateway "Solicita iniciar la clase"
            educloud.apiGateway -> educloud.liveClassService "Crea la sala de clase"
            educloud.liveClassService -> sfu "Solicita sala WebRTC"
            educloud.liveClassService -> educloud.eventBus "Publica: clase.iniciada"
            educloud.eventBus -> educloud.notifService "Notifica a inscritos"
        }

        dynamic educloud "FlujoKafkaEvaluaciones" "Evaluaciones -> Kafka -> Notificaciones" {
            educloud.evalService -> educloud.evalDB "Persiste calificación"
            educloud.evalService -> educloud.eventBus "Publica: evaluacion.calificada"
            educloud.eventBus -> educloud.notifService "Consume: evaluacion.calificada"
            educloud.notifService -> student "Notifica el resultado"
        }

        styles {
            element "Element" {
                shape roundedbox
                color #ffffff
                fontSize 13
            }
            element "Person" {
                shape person
                background #4388cc
            }
            element "Container" {
                background #11698e
            }
            element "Database" {
                shape cylinder
                background #067168
            }
            element "Event Bus" {
                shape hexagon
                background #6a1b9a
            }
            element "Object Store" {
                shape bucket
                background #616161
            }
            relationship "Relationship" {
                color #8d8d8d
                thickness 2
            }
            relationship "Event" {
                color #9c27b0
                thickness 2
                style dashed
            }
        }
    }
}